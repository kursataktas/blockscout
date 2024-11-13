defmodule Indexer.Fetcher.Optimism.Deposit do
  @moduledoc """
  Fills op_deposits DB table.
  """

  use GenServer
  use Indexer.Fetcher

  require Logger

  import Ecto.Query

  import EthereumJSONRPC, only: [integer_to_quantity: 1, quantity_to_integer: 1, request: 1]
  import Explorer.Helper, only: [decode_data: 2, parse_integer: 1]

  alias EthereumJSONRPC.Block.ByNumber
  alias EthereumJSONRPC.Blocks
  alias Explorer.{Chain, Repo}
  alias Explorer.Chain.Events.Publisher
  alias Explorer.Chain.Optimism.Deposit
  alias Indexer.Fetcher.Optimism
  alias Indexer.Helper

  defstruct [
    :batch_size,
    :start_block,
    :from_block,
    :safe_block,
    :optimism_portal,
    :json_rpc_named_arguments,
    :transaction_type,
    mode: :catch_up,
    filter_id: nil,
    check_interval: nil
  ]

  # 32-byte signature of the event TransactionDeposited(address indexed from, address indexed to, uint256 indexed version, bytes opaqueData)
  @transaction_deposited_event "0xb3813568d9991fc951961fcb4c784893574240a28925604d09fc577c55bb7c32"
  @retry_interval_minutes 3
  @retry_interval :timer.minutes(@retry_interval_minutes)
  @address_prefix "0x000000000000000000000000"
  @batch_size 500
  @fetcher_name :optimism_deposits

  def child_spec(start_link_arguments) do
    spec = %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, start_link_arguments},
      restart: :transient,
      type: :worker
    }

    Supervisor.child_spec(spec, [])
  end

  def start_link(args, gen_server_options \\ []) do
    GenServer.start_link(__MODULE__, args, Keyword.put_new(gen_server_options, :name, __MODULE__))
  end

  @impl GenServer
  def init(_args) do
    {:ok, %{}, {:continue, :ok}}
  end

  @impl GenServer
  def handle_continue(:ok, state) do
    Logger.metadata(fetcher: @fetcher_name)

    env = Application.get_all_env(:indexer)[__MODULE__]
    optimism_env = Application.get_all_env(:indexer)[Optimism]
    system_config = optimism_env[:optimism_l1_system_config]
    optimism_l1_rpc = optimism_env[:optimism_l1_rpc]

    with {:system_config_valid, true} <- {:system_config_valid, Helper.address_correct?(system_config)},
         {:rpc_l1_undefined, false} <- {:rpc_l1_undefined, is_nil(optimism_l1_rpc)},
         json_rpc_named_arguments = Optimism.json_rpc_named_arguments(optimism_l1_rpc),
         {optimism_portal, start_block_l1} <- Optimism.read_system_config(system_config, json_rpc_named_arguments),
         true <- start_block_l1 > 0,
         {last_l1_block_number, last_l1_transaction_hash, last_l1_transaction} <-
           Optimism.get_last_item(
             :L1,
             &Deposit.last_deposit_l1_block_number_query/0,
             &Deposit.remove_deposits_query/1,
             json_rpc_named_arguments
           ),
         {:l1_transaction_not_found, false} <-
           {:l1_transaction_not_found, !is_nil(last_l1_transaction_hash) && is_nil(last_l1_transaction)},
         {safe_block, _} = Helper.get_safe_block(json_rpc_named_arguments),
         {:start_block_l1_valid, true} <-
           {:start_block_l1_valid,
            (start_block_l1 <= last_l1_block_number || last_l1_block_number == 0) && start_block_l1 <= safe_block} do
      start_block = max(start_block_l1, last_l1_block_number)

      if start_block > safe_block do
        Process.send(self(), :switch_to_realtime, [])
      else
        Process.send(self(), :fetch, [])
      end

      {:noreply,
       %__MODULE__{
         start_block: start_block,
         from_block: start_block,
         safe_block: safe_block,
         optimism_portal: optimism_portal,
         json_rpc_named_arguments: json_rpc_named_arguments,
         batch_size: parse_integer(env[:batch_size]) || @batch_size,
         transaction_type: env[:transaction_type]
       }}
    else
      {:start_block_l1_valid, false} ->
        Logger.error("Invalid L1 Start Block value. Please, check the value and op_deposits table.")
        {:stop, :normal, state}

      {:rpc_l1_undefined, true} ->
        Logger.error("L1 RPC URL is not defined.")
        {:stop, :normal, state}

      {:system_config_valid, false} ->
        Logger.error("SystemConfig contract address is invalid or undefined.")
        {:stop, :normal, state}

      {:error, error_data} ->
        Logger.error("Cannot get last L1 transaction from RPC by its hash due to the RPC error: #{inspect(error_data)}")

        {:stop, :normal, state}

      {:l1_transaction_not_found, true} ->
        Logger.error(
          "Cannot find last L1 transaction from RPC by its hash. Probably, there was a reorg on L1 chain. Please, check op_deposits table."
        )

        {:stop, :normal, state}

      nil ->
        Logger.error("Cannot read SystemConfig contract.")
        {:stop, :normal, state}

      _ ->
        Logger.error("Optimism deposits L1 Start Block is invalid or zero.")
        {:stop, :normal, state}
    end
  end

  @impl GenServer
  def handle_info(
        :fetch,
        %__MODULE__{
          start_block: start_block,
          from_block: from_block,
          safe_block: safe_block,
          optimism_portal: optimism_portal,
          json_rpc_named_arguments: json_rpc_named_arguments,
          mode: :catch_up,
          batch_size: batch_size,
          transaction_type: transaction_type
        } = state
      ) do
    to_block = min(from_block + batch_size, safe_block)

    with {:logs, {:ok, logs}} <-
           {:logs,
            Optimism.get_logs(
              from_block,
              to_block,
              optimism_portal,
              @transaction_deposited_event,
              json_rpc_named_arguments,
              3
            )},
         _ = Helper.log_blocks_chunk_handling(from_block, to_block, start_block, safe_block, nil, :L1),
         deposits = events_to_deposits(logs, transaction_type, json_rpc_named_arguments),
         {:import, {:ok, _imported}} <-
           {:import, Chain.import(%{optimism_deposits: %{params: deposits}, timeout: :infinity})} do
      Publisher.broadcast(%{new_optimism_deposits: deposits}, :realtime)

      Helper.log_blocks_chunk_handling(
        from_block,
        to_block,
        start_block,
        safe_block,
        "#{Enum.count(deposits)} TransactionDeposited event(s)",
        :L1
      )

      if to_block == safe_block do
        Logger.info("Fetched all L1 blocks (#{start_block}..#{safe_block}), switching to realtime mode.")
        Process.send(self(), :switch_to_realtime, [])
        {:noreply, state}
      else
        Process.send(self(), :fetch, [])
        {:noreply, %{state | from_block: to_block + 1}}
      end
    else
      {:logs, {:error, _error}} ->
        Logger.error("Cannot fetch logs. Retrying in #{@retry_interval_minutes} minutes...")
        Process.send_after(self(), :fetch, @retry_interval)
        {:noreply, state}

      {:import, {:error, error}} ->
        Logger.error("Cannot import logs due to #{inspect(error)}. Retrying in #{@retry_interval_minutes} minutes...")
        Process.send_after(self(), :fetch, @retry_interval)
        {:noreply, state}

      {:import, {:error, step, failed_value, _changes_so_far}} ->
        Logger.error(
          "Failed to import #{inspect(failed_value)} during #{step}. Retrying in #{@retry_interval_minutes} minutes..."
        )

        Process.send_after(self(), :fetch, @retry_interval)
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(
        :switch_to_realtime,
        %__MODULE__{
          from_block: from_block,
          safe_block: safe_block,
          optimism_portal: optimism_portal,
          json_rpc_named_arguments: json_rpc_named_arguments,
          batch_size: batch_size,
          mode: :catch_up,
          transaction_type: transaction_type
        } = state
      ) do
    with {:check_interval, {:ok, check_interval, new_safe}} <-
           {:check_interval, Optimism.get_block_check_interval(json_rpc_named_arguments)},
         {:catch_up, _, false} <- {:catch_up, new_safe, new_safe - safe_block + 1 > batch_size},
         {:logs, {:ok, logs}} <-
           {:logs,
            Optimism.get_logs(
              max(safe_block, from_block),
              "latest",
              optimism_portal,
              @transaction_deposited_event,
              json_rpc_named_arguments,
              3
            )},
         {:ok, filter_id} <-
           get_new_filter(
             max(safe_block, from_block),
             "latest",
             optimism_portal,
             @transaction_deposited_event,
             json_rpc_named_arguments
           ) do
      handle_new_logs(logs, transaction_type, json_rpc_named_arguments)
      Process.send(self(), :fetch, [])
      {:noreply, %{state | mode: :realtime, filter_id: filter_id, check_interval: check_interval}}
    else
      {:catch_up, new_safe, true} ->
        Process.send(self(), :fetch, [])
        {:noreply, %{state | safe_block: new_safe}}

      {:logs, {:error, error}} ->
        Logger.error("Failed to get logs while switching to realtime mode, reason: #{inspect(error)}")
        Process.send_after(self(), :switch_to_realtime, @retry_interval)
        {:noreply, state}

      {:error, _error} ->
        Logger.error("Failed to set logs filter. Retrying in #{@retry_interval_minutes} minutes...")
        Process.send_after(self(), :switch_to_realtime, @retry_interval)
        {:noreply, state}

      {:check_interval, {:error, _error}} ->
        Logger.error("Failed to calculate check_interval. Retrying in #{@retry_interval_minutes} minutes...")
        Process.send_after(self(), :switch_to_realtime, @retry_interval)
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(
        :fetch,
        %__MODULE__{
          json_rpc_named_arguments: json_rpc_named_arguments,
          mode: :realtime,
          filter_id: filter_id,
          check_interval: check_interval,
          transaction_type: transaction_type
        } = state
      ) do
    case get_filter_changes(filter_id, json_rpc_named_arguments) do
      {:ok, logs} ->
        handle_new_logs(logs, transaction_type, json_rpc_named_arguments)
        Process.send_after(self(), :fetch, check_interval)
        {:noreply, state}

      {:error, error} ->
        Logger.error(
          "Failed to get filter changes. Error: #{error}. Retrying in #{@retry_interval_minutes} minutes. The new filter will be created."
        )

        Process.send_after(self(), :update_filter, @retry_interval)
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(
        :update_filter,
        %__MODULE__{
          optimism_portal: optimism_portal,
          json_rpc_named_arguments: json_rpc_named_arguments,
          mode: :realtime
        } = state
      ) do
    {last_l1_block_number, _, _} =
      Optimism.get_last_item(:L1, &Deposit.last_deposit_l1_block_number_query/0, &Deposit.remove_deposits_query/1)

    case get_new_filter(
           last_l1_block_number + 1,
           "latest",
           optimism_portal,
           @transaction_deposited_event,
           json_rpc_named_arguments
         ) do
      {:ok, filter_id} ->
        Process.send(self(), :fetch, [])
        {:noreply, %{state | filter_id: filter_id}}

      {:error, _error} ->
        Logger.error("Failed to set logs filter. Retrying in #{@retry_interval_minutes} minutes...")
        Process.send_after(self(), :update_filter, @retry_interval)
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({ref, _result}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  @impl GenServer
  def terminate(
        _reason,
        %__MODULE__{
          json_rpc_named_arguments: json_rpc_named_arguments
        } = state
      ) do
    if state.filter_id do
      Logger.info("Optimism deposits fetcher is terminating, uninstalling filter")
      uninstall_filter(state.filter_id, json_rpc_named_arguments)
    end
  end

  @impl GenServer
  def terminate(:normal, _state) do
    :ok
  end

  defp handle_new_logs(logs, transaction_type, json_rpc_named_arguments) do
    {reorgs, logs_to_parse, min_block, max_block, cnt} =
      logs
      |> Enum.reduce({MapSet.new(), [], nil, 0, 0}, fn
        %{"removed" => true, "blockNumber" => block_number}, {reorgs, logs_to_parse, min_block, max_block, cnt} ->
          {MapSet.put(reorgs, quantity_to_integer(block_number)), logs_to_parse, min_block, max_block, cnt}

        %{"blockNumber" => block_number} = log, {reorgs, logs_to_parse, min_block, max_block, cnt} ->
          {
            reorgs,
            [log | logs_to_parse],
            min(min_block, quantity_to_integer(block_number)),
            max(max_block, quantity_to_integer(block_number)),
            cnt + 1
          }
      end)

    handle_reorgs(reorgs)

    unless Enum.empty?(logs_to_parse) do
      deposits = events_to_deposits(logs_to_parse, transaction_type, json_rpc_named_arguments)
      {:ok, _imported} = Chain.import(%{optimism_deposits: %{params: deposits}, timeout: :infinity})

      Publisher.broadcast(%{new_optimism_deposits: deposits}, :realtime)

      Helper.log_blocks_chunk_handling(
        min_block,
        max_block,
        min_block,
        max_block,
        "#{cnt} TransactionDeposited event(s)",
        :L1
      )
    end
  end

  defp events_to_deposits(logs, transaction_type, json_rpc_named_arguments) do
    timestamps =
      logs
      |> Enum.reduce(MapSet.new(), fn %{"blockNumber" => block_number_quantity}, acc ->
        block_number = quantity_to_integer(block_number_quantity)
        MapSet.put(acc, block_number)
      end)
      |> MapSet.to_list()
      |> get_block_timestamps_by_numbers(json_rpc_named_arguments)
      |> case do
        {:ok, timestamps} ->
          timestamps

        {:error, error} ->
          Logger.error(
            "Failed to get L1 block timestamps for deposits due to #{inspect(error)}. Timestamps will be set to null."
          )

          %{}
      end

    Enum.map(logs, &event_to_deposit(&1, timestamps, transaction_type))
  end

  defp event_to_deposit(
         %{
           "blockHash" => "0x" <> stripped_block_hash,
           "blockNumber" => block_number_quantity,
           "transactionHash" => transaction_hash,
           "logIndex" => "0x" <> stripped_log_index,
           "topics" => [_, @address_prefix <> from_stripped, @address_prefix <> to_stripped, _],
           "data" => opaque_data
         },
         timestamps,
         transaction_type
       ) do
    {_, prefixed_block_hash} = (String.pad_leading("", 64, "0") <> stripped_block_hash) |> String.split_at(-64)
    {_, prefixed_log_index} = (String.pad_leading("", 64, "0") <> stripped_log_index) |> String.split_at(-64)

    deposit_id_hash =
      "#{prefixed_block_hash}#{prefixed_log_index}"
      |> Base.decode16!(case: :mixed)
      |> ExKeccak.hash_256()
      |> Base.encode16(case: :lower)

    source_hash =
      "#{String.pad_leading("", 64, "0")}#{deposit_id_hash}"
      |> Base.decode16!(case: :mixed)
      |> ExKeccak.hash_256()

    [
      <<
        msg_value::binary-size(32),
        value::binary-size(32),
        gas_limit::binary-size(8),
        _is_creation::binary-size(1),
        data::binary
      >>
    ] = decode_data(opaque_data, [:bytes])

    is_system = <<0>>

    rlp_encoded =
      ExRLP.encode(
        [
          source_hash,
          from_stripped |> Base.decode16!(case: :mixed),
          to_stripped |> Base.decode16!(case: :mixed),
          msg_value |> String.replace_leading(<<0>>, <<>>),
          value |> String.replace_leading(<<0>>, <<>>),
          gas_limit |> String.replace_leading(<<0>>, <<>>),
          is_system |> String.replace_leading(<<0>>, <<>>),
          data
        ],
        encoding: :hex
      )

    transaction_type =
      transaction_type
      |> Integer.to_string(16)
      |> String.downcase()

    l2_transaction_hash =
      "0x" <>
        ((transaction_type <> "#{rlp_encoded}")
         |> Base.decode16!(case: :mixed)
         |> ExKeccak.hash_256()
         |> Base.encode16(case: :lower))

    block_number = quantity_to_integer(block_number_quantity)

    %{
      l1_block_number: block_number,
      l1_block_timestamp: Map.get(timestamps, block_number),
      l1_transaction_hash: transaction_hash,
      l1_transaction_origin: "0x" <> from_stripped,
      l2_transaction_hash: l2_transaction_hash
    }
  end

  defp handle_reorgs(reorgs) do
    if MapSet.size(reorgs) > 0 do
      Logger.warning("L1 reorg detected. The following L1 blocks were removed: #{inspect(MapSet.to_list(reorgs))}")

      {deleted_count, _} = Repo.delete_all(from(d in Deposit, where: d.l1_block_number in ^reorgs))

      if deleted_count > 0 do
        Logger.warning(
          "As L1 reorg was detected, all affected rows were removed from the op_deposits table. Number of removed rows: #{deleted_count}."
        )
      end
    end
  end

  defp get_block_timestamps_by_numbers(numbers, json_rpc_named_arguments, retries \\ 3) do
    id_to_params =
      numbers
      |> Stream.map(fn number -> %{number: number} end)
      |> Stream.with_index()
      |> Enum.into(%{}, fn {params, id} -> {id, params} end)

    request = Blocks.requests(id_to_params, &ByNumber.request(&1, false))
    error_message = &"Cannot fetch timestamps for blocks #{numbers}. Error: #{inspect(&1)}"

    case Optimism.repeated_request(request, error_message, json_rpc_named_arguments, retries) do
      {:ok, response} ->
        %Blocks{blocks_params: blocks_params} = Blocks.from_responses(response, id_to_params)

        {:ok,
         blocks_params
         |> Enum.reduce(%{}, fn %{number: number, timestamp: timestamp}, acc -> Map.put_new(acc, number, timestamp) end)}

      err ->
        err
    end
  end

  defp get_new_filter(from_block, to_block, address, topic0, json_rpc_named_arguments, retries \\ 3) do
    processed_from_block = if is_integer(from_block), do: integer_to_quantity(from_block), else: from_block
    processed_to_block = if is_integer(to_block), do: integer_to_quantity(to_block), else: to_block

    req =
      request(%{
        id: 0,
        method: "eth_newFilter",
        params: [
          %{
            fromBlock: processed_from_block,
            toBlock: processed_to_block,
            address: address,
            topics: [topic0]
          }
        ]
      })

    error_message = &"Cannot create new log filter. Error: #{inspect(&1)}"

    Optimism.repeated_request(req, error_message, json_rpc_named_arguments, retries)
  end

  defp get_filter_changes(filter_id, json_rpc_named_arguments, retries \\ 3) do
    req =
      request(%{
        id: 0,
        method: "eth_getFilterChanges",
        params: [filter_id]
      })

    error_message = &"Cannot fetch filter changes. Error: #{inspect(&1)}"

    case Optimism.repeated_request(req, error_message, json_rpc_named_arguments, retries) do
      {:error, %{code: _, message: "filter not found"}} -> {:error, :filter_not_found}
      response -> response
    end
  end

  defp uninstall_filter(filter_id, json_rpc_named_arguments, retries \\ 1) do
    req =
      request(%{
        id: 0,
        method: "eth_uninstallFilter",
        params: [filter_id]
      })

    error_message = &"Cannot uninstall filter. Error: #{inspect(&1)}"

    Optimism.repeated_request(req, error_message, json_rpc_named_arguments, retries)
  end
end

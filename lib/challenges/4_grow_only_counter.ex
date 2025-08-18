defmodule GossipGlomers.Challenges.GrowOnlyCounter do
  @moduledoc """
  Links:
  - https://fly.io/dist-sys/4/
    - Challenge description
    - To test: `./maelstrom test -w g-counter --bin ./gossip_glomers g-counter --node-count 3 --rate 100 --time-limit 20 --nemesis partition`
      - Everything looks good! ヽ(‘ー`)ノ
  """
  use GossipGlomers.Challenge

  alias GossipGlomers.NodeState
  require Logger

  @impl GenServer
  def init(_args) do
    state =
      %NodeState{node_id: nil, node_ids: nil}
      |> Map.from_struct()
      |> Map.put(:pending_requests, %{})

    {:ok, state}
  end

  @impl GossipGlomers.Challenge
  def handle_init(message, state) do
    state
    |> Map.put(:node_id, message["body"]["node_id"])
    |> Map.put(:node_ids, message["body"]["node_ids"])
  end

  @impl GossipGlomers.Challenge
  def process_maelstrom_message(message, state) do
    case message["body"]["type"] do
      type when type in ["add", "read"] ->
        read_from_kv(message, state)

      "read_ok" ->
        handle_read_ok(message, state)

      "cas_ok" ->
        handle_cas_ok(message, state)

      "error" ->
        handle_error(message, state)

      type ->
        Logger.warning("Received unknown message type: #{type}")
        state
    end
  end

  defp handle_read_ok(message, state) do
    {original_message, next_state} = pop_pending_request(message, state)
    current_value = Map.get(message["body"], "value", %{})

    case original_message["body"]["type"] do
      "read" ->
        total_value = Enum.sum(Map.values(current_value))
        reply(original_message, "read_ok", %{"value" => total_value})
        next_state

      "add" ->
        node_id = state.node_id
        delta = original_message["body"]["delta"]
        new_value = Map.update(current_value, node_id, delta, &(&1 + delta))
        cas_kv(original_message, current_value, new_value, next_state)
    end
  end

  defp handle_cas_ok(message, state) do
    {original_message, next_state} = pop_pending_request(message, state)
    reply(original_message, "add_ok")
    next_state
  end

  defp handle_error(message, state) do
    {original_message, next_state} = pop_pending_request(message, state)
    error_code = message["body"]["code"]

    case {original_message["body"]["type"], error_code} do
      # Key does not exist
      {"read", 20} ->
        reply(original_message, "read_ok", %{"value" => 0})
        next_state

      # Key does not exist, so we create it
      {"add", 20} ->
        node_id = state.node_id
        delta = original_message["body"]["delta"]
        initial_value = %{node_id => delta}
        cas_kv(original_message, nil, initial_value, next_state, create_if_not_exists: true)

      # Precondition failed, retry by re-reading
      {_, 22} ->
        read_from_kv(original_message, next_state)

      {_, code} ->
        Logger.error("Unhandled lin-kv error code: #{code}")
        next_state
    end
  end

  defp read_from_kv(original_message, state) do
    body = %{"type" => "read", "key" => "counter"}
    {next_state, msg_id} = rpc("lin-kv", body, state)

    pending_requests = Map.put(state.pending_requests, msg_id, original_message)
    %{next_state | pending_requests: pending_requests}
  end

  defp cas_kv(original_message, from, to, state, opts \\ []) do
    create_if_not_exists = Keyword.get(opts, :create_if_not_exists, false)

    body = %{
      "type" => "cas",
      "key" => "counter",
      "from" => from,
      "to" => to,
      "create_if_not_exists" => create_if_not_exists
    }

    {next_state, msg_id} = rpc("lin-kv", body, state)

    pending_requests = Map.put(state.pending_requests, msg_id, original_message)
    %{next_state | pending_requests: pending_requests}
  end

  defp pop_pending_request(message, state) do
    in_reply_to = message["body"]["in_reply_to"]
    {original_message, pending_requests} = Map.pop!(state.pending_requests, in_reply_to)
    next_state = %{state | pending_requests: pending_requests}
    {original_message, next_state}
  end

  defp rpc(dest, body, state) do
    node_state_struct = struct(NodeState, state)
    next_node_state_struct = NodeState.increment_msg_id(node_state_struct)
    msg_id = next_node_state_struct.next_msg_id

    message = %{
      "src" => state.node_id,
      "dest" => dest,
      "body" => Map.put(body, "msg_id", msg_id)
    }

    ChallengeRunner.send_response(message)

    next_state = Map.merge(state, Map.from_struct(next_node_state_struct))
    {next_state, msg_id}
  end
end

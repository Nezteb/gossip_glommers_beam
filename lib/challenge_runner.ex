defmodule GossipGlomers.ChallengeRunner do
  @moduledoc """
  Handles the core message-processing loop for a Maelstrom challenge.

    This module is the engine that drives a challenge. It performs the following tasks:

    1. Starts the Challenge
      - Kicks off the specific challenge module's GenServer.
    2. Manages IO
      - Reads messages from standard input (`stdin`), line by line.
    3. Parses Messages
      - Decodes each line of input from JSON into an Elixir map.
    4. Dispatches to Challenge
      - Forwards the decoded message to the appropriate `handle_message/1` callback on the challenge module.
    5.Provides Helpers
      - Offers a set of helper functions (`send/3`, `reply/3`, etc.) to standardize and simplify
      the process of sending messages and replies, which is especially useful for challenges involving
      asynchronous communication with other nodes or services.

    The goal is to abstract away the boilerplate of Maelstrom communication, allowing each
    challenge module to focus purely on its own logic and state management.

  Docs:
  - https://github.com/jepsen-io/maelstrom/blob/main/resources/protocol-intro.md
  - https://github.com/jepsen-io/maelstrom/blob/main/doc/protocol.md
  """
  require Logger

  @doc """
  The main entry point for running a challenge.

  Starts the given `challenge_module` and then blocks, creating a stream that reads
  from standard input. Each line is passed to `process_line/2` for parsing and
  dispatching.
  """
  def run(challenge_module, args \\ []) do
    Logger.info("Starting challenge", challenge: challenge_module, args: inspect(args))

    {:ok, _pid} = challenge_module.start_link(args)

    # Block and wait for messages from stdin
    IO.stream(:stdio, :line)
    |> Stream.each(&process_line(&1, challenge_module))
    |> Stream.run()
  end

  @doc """
  A helper to handle the common logic for the Maelstrom `init` message.

  It automatically sends the required `init_ok` reply and bootstraps the node's
  state with the essential `node_id` and `node_ids` provided by Maelstrom.
  """
  def handle_init(message, state) do
    reply(message, "init_ok")

    state
    |> Map.put(:node_id, message["body"]["node_id"])
    |> Map.put(:node_ids, message["body"]["node_ids"])
  end

  def handle_unknown_message(message, state, module) do
    Logger.warning("Received unknown message", message: inspect(message), module: module)
    state
  end

  @doc """
  Sends a new message to a specified destination.

  This is a general-purpose sending function, useful for when a node needs to
  initiate communication rather than just replying to a received message.
  Useful for when a node to be a client to another service and must read or
  write a value by creating/sending a new request message.

  Simpler challenges are purely reactive; they only ever sent messages in
  direct response to other messages. This function provides the ability to be
  proactive, which is essential for the asynchronous, multi-step operations in
  the some challenges.
  """
  def send(src, dest, body) do
    message = %{"src" => src, "dest" => dest, "body" => body}
    send_response(message)
  end

  @doc """
  Builds and sends a reply to an original message.

  Useful for  asynchronous operations where a client request may not be answered immediately.
  Instead, its fate is stored in the node's state while other messages are sent. When the final
  result is ready, the node needs to find the original message in its state and send a reply.
  """
  def reply(original_message, type, extra_body \\ %{}) do
    original_message
    |> build_reply(type, extra_body)
    |> send_response()
  end

  @doc """
  Constructs a reply message map based on an original message.

  This utility swaps the `src` and `dest` fields and sets the `in_reply_to`
  body field to the `msg_id` of the original message, which is required by the
  Maelstrom protocol.
  """
  def build_reply(original_message, type, extra_body \\ %{}) do
    body = %{
      "type" => type,
      "in_reply_to" => original_message["body"]["msg_id"]
    }

    %{
      "src" => original_message["dest"],
      "dest" => original_message["src"],
      "body" => Map.merge(body, extra_body)
    }
  end

  def send_response(message) do
    Logger.info("Sending response", message: inspect(message))
    IO.puts(Jason.encode!(message))
  end

  defp process_line(line, challenge_module) do
    Logger.info("Received line", line: line)

    case Jason.decode(line) do
      {:ok, message} ->
        challenge_module.handle_message(message)

      {:error, reason} ->
        Logger.error("Error decoding JSON", line: line, reason: reason)
    end
  end
end

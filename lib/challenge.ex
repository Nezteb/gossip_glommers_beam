defmodule GossipGlomers.Challenge do
  @moduledoc """
  A behaviour for a Maelstrom challenge.

  Docs:
  - https://github.com/jepsen-io/maelstrom/blob/main/resources/protocol-intro.md
  - https://github.com/jepsen-io/maelstrom/blob/main/doc/protocol.md
  """

  @callback process_maelstrom_message(message :: map(), state :: GossipGlomers.NodeState.t()) ::
              GossipGlomers.NodeState.t()

  @callback handle_init(message :: map(), state :: GossipGlomers.NodeState.t()) ::
              GossipGlomers.NodeState.t()

  defmacro __using__(_opts) do
    quote do
      use GenServer
      require Logger

      alias GossipGlomers.ChallengeRunner
      alias GossipGlomers.NodeState

      @behaviour GossipGlomers.Challenge

      def start_link(args) do
        GenServer.start_link(__MODULE__, args, name: __MODULE__)
      end

      @doc "The main entry point for running a challenge."
      def run(args \\ []) do
        ChallengeRunner.run(__MODULE__, args)
      end

      def handle_message(message) do
        GenServer.cast(__MODULE__, {:handle_message, message})
      end

      @impl true
      def init(_args) do
        {:ok, %NodeState{node_id: nil, node_ids: nil}}
      end

      @impl true
      def handle_cast({:handle_message, %{"body" => %{"type" => "init"}} = message}, state) do
        Logger.info("Initializing node", message: inspect(message))
        ChallengeRunner.reply(message, "init_ok")
        next_state = handle_init(message, state)
        {:noreply, next_state}
      end

      def handle_cast({:handle_message, message}, state) do
        next_state = process_maelstrom_message(message, state)
        {:noreply, next_state}
      end

      def handle_init(message, state) do
        Logger.warning(
          "#{__MODULE__} received an init message but does not implement handle_init/2, using default implementation. Message: #{inspect(message)}"
        )

        ChallengeRunner.handle_init(message, state)
      end

      def process_maelstrom_message(message, state) do
        Logger.warning(
          "#{__MODULE__} received an unhandled message, please implement process_maelstrom_message/2: #{inspect(message)}"
        )

        state
      end

      def reply(original_message, type, extra_body \\ %{}) do
        original_message
        |> ChallengeRunner.build_reply(type, extra_body)
        |> ChallengeRunner.send_response()
      end

      defoverridable process_maelstrom_message: 2,
                     handle_cast: 2,
                     init: 1,
                     handle_init: 2,
                     run: 1
    end
  end
end

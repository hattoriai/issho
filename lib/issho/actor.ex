defprotocol Issho.Actor do
  @moduledoc ~S"""
  Anyone or anything that takes part in a room: a user, an admin, a guest,
  a service, an agent. Issho never assumes your schema; implement this
  protocol for each struct that can join.

      defimpl Issho.Actor, for: MyApp.Accounts.User do
        def key(user), do: "user:#{user.id}"
        def display(user), do: %{name: user.name, avatar: user.avatar_url, kind: :human}
      end

      defimpl Issho.Actor, for: MyApp.Agents.Agent do
        def key(agent), do: "agent:#{agent.id}"
        def display(agent), do: %{name: agent.name, kind: :agent}
      end

  `key/1` is the actor's identity in every room: namespace it, so that
  admin 4 is not user 4. Two tabs of one actor share a key, and others see
  one person.

  `display/1` is what the other people in a room see, so give it only what
  they may see: `:name`, `:avatar` (an image's URL), `:color` (a CSS
  colour) and `:kind` (`:human`, `:agent` or `:service`, `:human` unless
  given). Issho checks the colour before it reaches anyone's browser.

  Maps with an `:id` work without an implementation, for scripts and
  tests: `%{id: 4, name: "Ada"}` is the actor `"4"`.
  """

  @fallback_to_any true

  @doc "The actor's identity in every room, the same in every tab and node."
  @spec key(t()) :: String.t()
  def key(actor)

  @doc "What the other people in a room see of the actor."
  @spec display(t()) :: map()
  def display(actor)
end

defimpl Issho.Actor, for: Any do
  def key(%{id: id}), do: to_string(id)

  def key(actor) do
    raise Protocol.UndefinedError,
      protocol: Issho.Actor,
      value: actor,
      description: "implement Issho.Actor for it, or give a map with an :id"
  end

  def display(%{} = actor), do: Map.take(actor, [:name, :avatar, :color, :kind])
end

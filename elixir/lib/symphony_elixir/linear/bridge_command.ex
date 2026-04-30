defmodule SymphonyElixir.Linear.BridgeCommand do
  @moduledoc """
  Explicit Linear comment commands handled by Symphony's bridge layer.

  The bridge only treats top-level human comments that start with `symphony`
  as commands. Everything else remains agent context.
  """

  alias SymphonyElixir.Linear.Comment

  @actions ~w(help status pause resume retry cancel)

  @type action :: :help | :status | :pause | :resume | :retry | :cancel
  @type t :: %{
          action: action(),
          action_text: String.t(),
          raw: String.t(),
          args: String.t()
        }

  @spec parse(Comment.t()) :: {:ok, t()} | :not_command | {:error, :unknown_command, String.t()}
  def parse(%Comment{author_is_bot: true}), do: :not_command
  def parse(%Comment{parent_id: parent_id}) when is_binary(parent_id), do: :not_command

  def parse(%Comment{body: body}) when is_binary(body) do
    trimmed = String.trim(body)

    with true <- command_prefix?(trimmed),
         rest <- trimmed |> String.slice(8..-1//1) |> to_string() |> String.trim(),
         {action_text, args} <- split_action(rest) do
      case normalize_action(action_text) do
        {:ok, action} ->
          {:ok, %{action: action, action_text: Atom.to_string(action), raw: trimmed, args: args}}

        :unknown ->
          {:error, :unknown_command, action_text}
      end
    else
      _ -> :not_command
    end
  end

  def parse(_comment), do: :not_command

  @spec command?(Comment.t()) :: boolean()
  def command?(%Comment{} = comment), do: match?({:ok, _}, parse(comment)) or match?({:error, :unknown_command, _}, parse(comment))
  def command?(_comment), do: false

  @spec help_text() :: String.t()
  def help_text do
    "Commands: `symphony status`, `symphony pause`, `symphony resume`, `symphony retry`, `symphony cancel`, `symphony help`."
  end

  defp command_prefix?(trimmed) when byte_size(trimmed) >= 8 do
    prefix = String.slice(trimmed, 0, 8)
    rest = String.slice(trimmed, 8..-1//1)

    String.downcase(prefix) == "symphony" and
      (rest == "" or String.match?(String.first(rest) || "", ~r/\s/))
  end

  defp command_prefix?(_trimmed), do: false

  defp split_action("") do
    {"help", ""}
  end

  defp split_action(rest) when is_binary(rest) do
    case String.split(rest, ~r/\s+/, parts: 2) do
      [action] -> {action, ""}
      [action, args] -> {action, String.trim(args)}
    end
  end

  defp normalize_action(action) when is_binary(action) do
    normalized =
      action
      |> String.downcase()
      |> String.trim()

    if normalized in @actions do
      {:ok, String.to_existing_atom(normalized)}
    else
      :unknown
    end
  end
end

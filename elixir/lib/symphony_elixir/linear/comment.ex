defmodule SymphonyElixir.Linear.Comment do
  @moduledoc """
  Normalized Linear issue comment data used for comment steering.
  """

  @enforce_keys [:id]
  defstruct [
    :id,
    :body,
    :created_at,
    :updated_at,
    :author_id,
    :author_name,
    :parent_id,
    author_is_bot: false
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          body: String.t() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          author_id: String.t() | nil,
          author_name: String.t() | nil,
          parent_id: String.t() | nil,
          author_is_bot: boolean()
        }
end

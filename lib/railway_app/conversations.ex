defmodule RailwayApp.Conversations do
  @moduledoc """
  Context for managing conversation sessions and messages.
  """

  import Ecto.Query
  alias RailwayApp.Repo
  alias RailwayApp.{ConversationSession, ConversationMessage}

  # Session Functions

  @doc """
  Creates a conversation session.
  """
  def create_session(attrs \\ %{}) do
    %ConversationSession{}
    |> ConversationSession.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets a conversation session by ID.
  """
  def get_session(id), do: Repo.get(ConversationSession, id)

  @doc """
  Gets a conversation session by channel reference.
  """
  def get_session_by_channel_ref(channel_ref) do
    from(s in ConversationSession,
      where: s.channel_ref == ^channel_ref and is_nil(s.closed_at),
      order_by: [desc: s.started_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Updates a conversation session.
  """
  def update_session(%ConversationSession{} = session, attrs) do
    session
    |> ConversationSession.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Closes a conversation session.
  """
  def close_session(%ConversationSession{} = session) do
    update_session(session, %{closed_at: DateTime.utc_now()})
  end

  @doc """
  Lists recent conversation sessions.

  Options:
  - `:limit` - Maximum number of sessions to return (default: 50)
  - `:offset` - Number of sessions to skip
  """
  def list_sessions(opts \\ []) do
    {limit, offset} =
      cond do
        is_integer(opts) ->
          {opts, 0}

        is_map(opts) ->
          {
            normalize_int(Map.get(opts, :limit) || Map.get(opts, "limit"), 50),
            normalize_int(Map.get(opts, :offset) || Map.get(opts, "offset"), 0)
          }

        is_list(opts) ->
          {
            normalize_int(Keyword.get(opts, :limit, 50), 50),
            normalize_int(Keyword.get(opts, :offset, 0), 0)
          }

        true ->
          {50, 0}
      end

    from(s in ConversationSession,
      order_by: [desc: s.started_at],
      limit: ^limit,
      offset: ^offset,
      preload: [:incident]
    )
    |> Repo.all()
  end

  @doc """
  Counts all conversation sessions.
  """
  def count_sessions do
    Repo.aggregate(ConversationSession, :count, :id)
  end

  # Message Functions

  @doc """
  Creates a conversation message.
  """
  def create_message(attrs \\ %{}) do
    %ConversationMessage{}
    |> ConversationMessage.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists messages for a session.
  """
  def list_messages(session_id) do
    from(m in ConversationMessage,
      where: m.session_id == ^session_id,
      order_by: [asc: m.timestamp]
    )
    |> Repo.all()
  end

  @doc """
  Gets the latest message in a session.
  """
  def get_latest_message(session_id) do
    from(m in ConversationMessage,
      where: m.session_id == ^session_id,
      order_by: [desc: m.timestamp],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Deletes old conversation sessions and messages.
  """
  def delete_old_conversations(days \\ 90) do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    from(s in ConversationSession, where: s.started_at < ^cutoff_date)
    |> Repo.delete_all()
  end

  defp normalize_int(value, default) do
    cond do
      is_integer(value) ->
        value

      is_binary(value) ->
        case Integer.parse(value) do
          {int, _} -> int
          :error -> default
        end

      true ->
        default
    end
  end
end

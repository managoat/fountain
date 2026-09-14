defmodule Fountain.Team.Contact do
  @moduledoc """
  A teammate's email address and phone number — the AgentMail inbox and
  AgentPhone number Fountain provisioned for it (`Fountain.Team.Comms`).

  Keyed by `(user_id, agent_id)`, the pair that names a teammate, so it
  survives the teammate's conversation being replaced. Either channel may be
  absent (the provider declined, or was not configured) — `email?/1` and
  `phone?/1` say which the teammate actually has.

  `prompt_from_number` is the one number whose texts to the teammate's number
  arrive as prompts in its conversation (`Fountain.Team.Comms.Inbound`) —
  the owner's phone, collected whenever a number is given. Stored E.164.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "team_contacts" do
    field :email_address, :string
    field :email_inbox_id, :string
    field :phone_number, :string
    field :phone_number_id, :string
    # The AgentPhone "agent" (persona) the number is attached to — AgentPhone
    # only sends from an attached number. Ours, created per teammate.
    field :phone_agent_id, :string
    field :prompt_from_number, :string
    # Set when the registered number texted STOP; cleared by START or by a
    # fresh number (new consent). While set, its texts are not prompts.
    field :prompt_opted_out_at, :utc_datetime

    belongs_to :user, Fountain.Accounts.User
    belongs_to :agent, Fountain.Agents.Agent

    timestamps(type: :utc_datetime)
  end

  @fields [
    :user_id,
    :agent_id,
    :email_address,
    :email_inbox_id,
    :phone_number,
    :phone_number_id,
    :phone_agent_id,
    :prompt_from_number,
    :prompt_opted_out_at
  ]

  def changeset(contact, attrs) do
    contact
    |> cast(attrs, @fields)
    |> validate_required([:user_id, :agent_id])
    |> normalize_number(:prompt_from_number)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:agent_id)
    |> unique_constraint([:user_id, :agent_id])
  end

  @doc """
  What the user supplies when giving a teammate a contact — today just the
  number whose texts become prompts, required and E.164-normalized. Run
  before anything is bought upstream, so a typo costs nothing.
  """
  def request_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:prompt_from_number])
    |> validate_required([:prompt_from_number])
    |> normalize_number(:prompt_from_number)
  end

  @doc """
  Change the user-supplied part of an existing contact: `prompt_from_number`,
  required. Entering a number is consent again, so a standing STOP is cleared.
  """
  def update_changeset(%__MODULE__{} = contact, attrs) do
    contact
    |> cast(attrs, [:prompt_from_number])
    |> validate_required([:prompt_from_number])
    |> normalize_number(:prompt_from_number)
    |> put_change(:prompt_opted_out_at, nil)
  end

  @doc "Whether the registered number has opted out (texted STOP)."
  def opted_out?(%__MODULE__{prompt_opted_out_at: at}), do: not is_nil(at)

  defp normalize_number(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      value ->
        case Fountain.Team.Comms.Phone.normalize(value) do
          {:ok, e164} ->
            put_change(changeset, field, e164)

          :error ->
            add_error(
              changeset,
              field,
              "must be a phone number with country code, e.g. +15551234567"
            )
        end
    end
  end

  def email?(%__MODULE__{email_inbox_id: id}), do: is_binary(id) and id != ""
  def phone?(%__MODULE__{phone_number_id: id}), do: is_binary(id) and id != ""
end

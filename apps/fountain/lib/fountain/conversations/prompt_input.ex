defmodule Fountain.Conversations.PromptInput do
  @moduledoc """
  Validate opening input before a launch reserves a sandbox or creates a conversation.

  `validate_initial/1` runs as the first step of `start_conversation/2` on both
  the create and attach paths, ahead of the agent fetch and every reservation,
  so malformed input costs no machine.

  The rule is that images need words. A launch with neither is fine — that is
  how a conversation opens without a first turn — but images with a blank or
  absent prompt are refused, because the runtime is handed pixels and no
  instruction. The retired OpenAI-compatible controller decided the other way
  for its own dialect and synthesized a caption; that was a shim for clients
  that could not send one, never the native contract, and it left with the
  dialect (ADR 0057).

  The media-type and size checks repeat what `FountainWeb.PromptImages.decode/1`
  already did. That is deliberate: `decode/1` belongs to the two HTTP
  transports, and a context caller (a future worker) reaches `start_conversation/2` without passing through it. The web
  layer's message is the friendlier one and still wins for HTTP callers,
  because it runs first.

  `attrs["images"]` is the **decoded** shape — `[%{media_type: binary, data: binary}]`
  with atom keys and raw bytes, which is what `PromptImages.decode/1` returns and
  what every caller already passes. This is not a preference. It is the shape the
  rest of the pipeline pattern-matches on, so accepting anything else here would
  only move the failure later and make it worse:

      Conversations._unsafe_insert_turn_images/2   fn {%{media_type: mt, data: data}, idx} -> ...

  `TurnMachine.store_images/2` is on every runtime's path
  (`ConversationServer.run_turn/6`, before sending the ACP prompt) and handles an
  `{:error, changeset}` by logging and continuing — but a key it cannot match
  raises `FunctionClauseError`, which is not an error tuple and which no `rescue`
  on that path catches. A validator that said `:ok` to a shape these consumers cannot
  read would trade a free refusal for a crashed turn on a sandbox the tenant had
  already paid to provision, which is the opposite of the point of validating
  here at all.

  So an image that is not the decoded shape is `{:error, :invalid_images}`, and
  a caller that has bytes of its own runs them through
  `FountainWeb.PromptImages.decode/1` first.
  """

  alias Fountain.Images

  @doc """
  `:ok`, `{:error, :invalid_prompt}` or `{:error, :invalid_images}` for the
  opening `prompt` and `images` of a launch. Both keys are optional; `attrs`
  is the string-keyed map `start_conversation/2` takes.
  """
  @spec validate_initial(map()) :: :ok | {:error, :invalid_prompt | :invalid_images}
  def validate_initial(attrs) do
    case {attrs["prompt"], attrs["images"] || []} do
      {prompt, []} when prompt in [nil, ""] -> :ok
      {prompt, images} -> validate_payload(prompt, images)
    end
  end

  defp validate_payload(prompt, images) when is_binary(prompt) and is_list(images) do
    cond do
      String.trim(prompt) == "" -> {:error, :invalid_prompt}
      Enum.any?(images, &(not valid_image?(&1))) -> {:error, :invalid_images}
      true -> :ok
    end
  end

  defp validate_payload(_, _), do: {:error, :invalid_prompt}

  # A pattern match, not `Map.get/2` or Access: this is the decoded shape or it
  # is nothing, and a struct or a string-keyed map falls to the clause below
  # rather than raising.
  defp valid_image?(%{media_type: media_type, data: data}) when is_binary(data),
    do:
      Images.valid_media_type?(media_type) and byte_size(data) > 0 and
        byte_size(data) <= Images.max_prompt_image_bytes()

  defp valid_image?(_), do: false
end

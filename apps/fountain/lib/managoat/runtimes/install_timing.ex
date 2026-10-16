defmodule Managoat.Runtimes.InstallTiming do
  @moduledoc false

  # Only fixed numeric fields cross from installer output into telemetry. Never
  # export stdout, URLs, package names, command arguments or environment values.
  @phases ~w(cache_hit lock_wait image_probe manifest npm finalize link)
  @download_fields ~w(dns connect tls first_byte total bytes)

  def attributes(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.reduce(%{}, &record/2)
  end

  def attributes(_), do: %{}

  defp record("__MANAGOAT_INSTALL__ " <> record, attrs) do
    case String.split(record) do
      [phase, value] when phase in @phases ->
        case Integer.parse(value) do
          {value, ""} when value >= 0 and value <= 180_000 ->
            Map.put(
              attrs,
              if(phase == "cache_hit",
                do: "install_cache_hit",
                else: "install_" <> phase <> "_ms"
              ),
              value
            )

          _ ->
            attrs
        end

      _ ->
        attrs
    end
  end

  defp record("__MANAGOAT_DOWNLOAD__ " <> record, attrs) do
    values = String.split(record)

    parsed = Enum.map(values, &Float.parse/1)

    if length(values) == length(@download_fields) and
         Enum.all?(parsed, &match?({n, ""} when n >= 0 and n <= 1_000_000_000, &1)) do
      Enum.zip(@download_fields, parsed)
      |> Enum.reduce(Map.update(attrs, "download_attempts", 1, &(&1 + 1)), &download_max/2)
    else
      attrs
    end
  end

  defp record(_, attrs), do: attrs
  # Curl times are cumulative milestones, not disjoint phases. Maxima may
  # belong to different packages because downloads run in parallel.
  defp download_max({field, {value, ""}}, attrs) do
    {key, value} =
      if field == "bytes",
        do: {"download_bytes_max", value},
        else: {"download_" <> field <> "_max_ms", value * 1000}

    Map.update(attrs, key, value, &max(&1, value))
  end
end

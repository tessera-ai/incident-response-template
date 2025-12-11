#!/usr/bin/env elixir

# Validates railpack.json against basic structural expectations.
# Run with: mix run scripts/validate_railpack.exs

defmodule RailpackValidator do
  @railpack_path "railpack.json"

  def run do
    case File.read(@railpack_path) do
      {:ok, body} ->
        with {:ok, config} <- Jason.decode(body) do
          IO.puts("Current railpack.json structure:")
          IO.puts(Jason.encode!(config, pretty: true))
          IO.puts("\n=== Basic Validation ===")

          check_field(config, "$schema", "schema field")
          check_field(config, "provider", "provider field")

          check_caches(config)
          check_steps(config)
          check_deploy(config)
        else
          {:error, reason} ->
            IO.puts("✗ Failed to decode railpack.json: #{inspect(reason)}")
        end

      {:error, reason} ->
        IO.puts("✗ Could not read #{@railpack_path}: #{inspect(reason)}")
    end
  end

  defp check_field(config, key, label) do
    if Map.has_key?(config, key) do
      IO.puts("✓ Has #{label}")
    else
      IO.puts("✗ Missing #{label}")
    end
  end

  defp check_caches(%{"caches" => caches}) when is_map(caches) do
    IO.puts("✓ Has caches section")

    Enum.each(caches, fn {name, cache} ->
      cond do
        is_map(cache) and Map.has_key?(cache, "directory") and Map.has_key?(cache, "type") ->
          IO.puts("✓ Cache '#{name}' has required fields")

        true ->
          IO.puts("✗ Cache '#{name}' missing required fields (needs directory and type)")
      end
    end)
  end

  defp check_caches(_), do: IO.puts("✗ Missing caches section")

  defp check_steps(%{"steps" => steps}) when is_map(steps) do
    IO.puts("✓ Has steps section")

    Enum.each(steps, fn {name, step} ->
      if is_map(step) and Map.has_key?(step, "commands") do
        IO.puts("✓ Step '#{name}' has commands")
      else
        IO.puts("✗ Step '#{name}' missing commands")
      end
    end)
  end

  defp check_steps(_), do: IO.puts("✗ Missing steps section")

  defp check_deploy(%{"deploy" => deploy}) when is_map(deploy) do
    IO.puts("✓ Has deploy section")

    if Map.has_key?(deploy, "startCommand") do
      IO.puts("✓ Deploy has startCommand")
    else
      IO.puts("✗ Deploy missing startCommand")
    end
  end

  defp check_deploy(_), do: IO.puts("✗ Missing deploy section")
end

RailpackValidator.run()

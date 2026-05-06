defmodule SymphonyElixir.Workflow do
  @moduledoc """
  Loads Symphony configuration and the repo-owned workflow prompt.

  Runtime configuration is read from `.symphony/config.yml` when present.
  `WORKFLOW.md` remains the prompt template source and can still carry
  front matter for existing deployments and tests.
  """

  alias SymphonyElixir.WorkflowStore

  @workflow_file_name "WORKFLOW.md"
  @config_file_name "config.yml"

  @spec workflow_file_path() :: Path.t()
  def workflow_file_path do
    Application.get_env(:symphony_elixir, :workflow_file_path) ||
      Path.join(File.cwd!(), @workflow_file_name)
  end

  @spec config_file_path() :: Path.t()
  def config_file_path do
    Application.get_env(:symphony_elixir, :config_file_path) ||
      default_config_file_path(workflow_file_path())
  end

  @spec set_config_file_path(Path.t()) :: :ok
  def set_config_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :config_file_path, path)
    maybe_reload_store()
    :ok
  end

  @spec clear_config_file_path() :: :ok
  def clear_config_file_path do
    Application.delete_env(:symphony_elixir, :config_file_path)
    maybe_reload_store()
    :ok
  end

  @spec set_workflow_file_path(Path.t()) :: :ok
  def set_workflow_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :workflow_file_path, path)
    maybe_reload_store()
    :ok
  end

  @spec clear_workflow_file_path() :: :ok
  def clear_workflow_file_path do
    Application.delete_env(:symphony_elixir, :workflow_file_path)
    maybe_reload_store()
    :ok
  end

  @type loaded_workflow :: %{
          config: map(),
          prompt: String.t(),
          prompt_template: String.t()
        }

  @spec current() :: {:ok, loaded_workflow()} | {:error, term()}
  def current do
    case Process.whereis(WorkflowStore) do
      pid when is_pid(pid) ->
        WorkflowStore.current()

      _ ->
        load()
    end
  end

  @spec load() :: {:ok, loaded_workflow()} | {:error, term()}
  def load do
    load(workflow_file_path())
  end

  @spec load(Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        parse(content, config_file_path_for_workflow(path))

      {:error, reason} ->
        {:error, {:missing_workflow_file, path, reason}}
    end
  end

  defp parse(content, config_path) do
    {front_matter_lines, prompt_lines} = split_front_matter(content)

    case front_matter_yaml_to_map(front_matter_lines) do
      {:ok, front_matter} ->
        prompt = Enum.join(prompt_lines, "\n") |> String.trim()

        with {:ok, config} <- load_external_config(config_path, front_matter) do
          {:ok,
           %{
             config: config,
             prompt: prompt,
             prompt_template: prompt
           }}
        end

      {:error, :workflow_front_matter_not_a_map} ->
        {:error, :workflow_front_matter_not_a_map}

      {:error, reason} ->
        {:error, {:workflow_parse_error, reason}}
    end
  end

  defp load_external_config(config_path, front_matter) do
    case File.read(config_path) do
      {:ok, yaml} ->
        case YamlElixir.read_from_string(yaml) do
          {:ok, decoded} when is_map(decoded) ->
            {:ok, decoded}

          {:ok, _decoded} ->
            {:error, {:invalid_external_config, config_path, :config_not_a_map}}

          {:error, reason} ->
            {:error, {:invalid_external_config, config_path, reason}}
        end

      {:error, _reason} ->
        {:ok, front_matter}
    end
  end

  defp split_front_matter(content) do
    lines = String.split(content, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        {front, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | prompt_lines] -> {front, prompt_lines}
          _ -> {front, []}
        end

      _ ->
        {[], lines}
    end
  end

  defp front_matter_yaml_to_map(lines) do
    yaml = Enum.join(lines, "\n")

    if String.trim(yaml) == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(yaml) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _} -> {:error, :workflow_front_matter_not_a_map}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp config_file_path_for_workflow(workflow_path) do
    Application.get_env(:symphony_elixir, :config_file_path) ||
      default_config_file_path(workflow_path)
  end

  defp default_config_file_path(workflow_path) do
    workflow_path
    |> Path.dirname()
    |> Path.join(@config_file_name)
  end

  defp maybe_reload_store do
    if Process.whereis(WorkflowStore) do
      _ = WorkflowStore.force_reload()
    end

    :ok
  end
end

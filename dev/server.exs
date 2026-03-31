# Dev server script - boots a standalone Aludel instance for development.
# Usage: elixir --erl "-noinput" -S mix run dev/server.exs --no-halt

Logger.configure(level: :debug)

# --- Dev Repo ---
defmodule Aludel.Dev.Repo do
  use Ecto.Repo, otp_app: :aludel, adapter: Ecto.Adapters.Postgres
end

# --- Dev Router ---
defmodule Aludel.Dev.Router do
  use Phoenix.Router

  import Aludel.Web.Router

  pipeline :browser do
    plug :fetch_session
    plug :fetch_flash
  end

  scope "/" do
    pipe_through :browser
    aludel_dashboard("/")
  end
end

# --- Dev Endpoint ---
defmodule Aludel.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :aludel

  socket "/live", Phoenix.LiveView.Socket

  plug Phoenix.CodeReloader

  plug Plug.Session,
    store: :cookie,
    key: "_aludel_dev_key",
    signing_salt: "dev_salt"

  plug Aludel.Dev.Router
end

# --- Configure ---
db_url =
  System.get_env("DATABASE_URL") || "postgres://postgres:postgres@localhost:5432/aludel_dev"

parsed = URI.parse(db_url)
[username, password] = String.split(parsed.userinfo || "postgres:postgres", ":")
database = String.trim_leading(parsed.path || "/aludel_dev", "/")

Application.put_env(:aludel, :repo, Aludel.Dev.Repo)
Application.put_env(:aludel, :ecto_repos, [Aludel.Dev.Repo])

Application.put_env(:aludel, Aludel.Dev.Repo,
  hostname: parsed.host || "localhost",
  port: parsed.port || 5432,
  username: username,
  password: password,
  database: database,
  show_sensitive_data_on_connection_error: true,
  stacktrace: true,
  pool_size: 10
)

port = String.to_integer(System.get_env("PORT") || "4000")

Application.put_env(:aludel, Aludel.Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {0, 0, 0, 0}, port: port],
  server: true,
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "dev_signing_salt"],
  render_errors: [formats: [html: Aludel.Web.ErrorHTML], layout: false],
  pubsub_server: Aludel.PubSub,
  watchers: [],
  url: [host: "localhost"]
)

Application.put_env(:phoenix, :json_library, Jason)

# --- Error modules (required by endpoint) ---
unless Code.ensure_loaded?(Aludel.Web.ErrorHTML) do
  defmodule Aludel.Web.ErrorHTML do
    use Phoenix.Component

    def render(template, _assigns) do
      Phoenix.Controller.status_message_from_template(template)
    end
  end
end

# --- Boot ---

repo_config = Application.get_env(:aludel, Aludel.Dev.Repo)

# Wait for postgres to be ready, then create the database
IO.puts("Waiting for database...")

Enum.reduce_while(1..30, :error, fn attempt, _acc ->
  case Ecto.Adapters.Postgres.storage_up(repo_config) do
    :ok ->
      IO.puts("Database created!")
      {:halt, :ok}

    {:error, :already_up} ->
      IO.puts("Database exists.")
      {:halt, :ok}

    {:error, reason} ->
      IO.puts("Attempt #{attempt}/30 - #{inspect(reason)}")
      Process.sleep(2_000)
      {:cont, :error}
  end
end)
|> case do
  :ok -> :ok
  :error -> raise "Could not connect to database after retries"
end

# Start required services under a supervisor to keep the BEAM alive.
# Note: PubSub is already started by Aludel.Application.
children = [
  Aludel.Dev.Repo,
  Aludel.Web.Endpoint
]

{:ok, _} = Supervisor.start_link(children, strategy: :one_for_one)

# Run migrations after repo is up
migrations_path = "test/support/migrations"
Ecto.Migrator.run(Aludel.Dev.Repo, migrations_path, :up, all: true, log: :info)

IO.puts("\n  Aludel dev server running at http://localhost:#{port}\n")

# Keep the BEAM alive — belt-and-suspenders with --no-halt
Process.sleep(:infinity)

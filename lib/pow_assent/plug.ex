defmodule PowAssent.Plug do
  @moduledoc """
  Plug helper methods.
  """
  alias Plug.Conn
  alias PowAssent.{Config, Operations}

  @doc """
  Calls the authentication method for the strategy provider.

  A generated redirection URL will be returned.
  """
  @spec authenticate(Conn.t(), binary(), binary()) :: {:ok, binary(), Conn.t()} | {:error. any(), Conn.t()}
  def authenticate(conn, provider, callback_url) do
    {strategy, provider_config} = get_provider_config(conn, provider)

    provider_config
    |> Pow.Config.put(:redirect_uri, callback_url)
    |> strategy.authorize_url(conn)
    |> case do
      {:ok, %{url: url, conn: conn}}        -> {:ok, url, conn}
      {:error, %{conn: conn, error: error}} -> {:error, error, conn}
    end
  end

  @doc """
  Calls the callback method for the strategy provider.

  A user will be created if a user doesn't already exists in connection or for
  the associated user identity. If a matching user identity association doesn't
  exist for the current user, a new user identity is created. Otherwise user is
  authenticated.
  """
  @spec callback(Conn.t(), binary(), map()) :: {:ok, map(), Conn.t()} |
                                               {:error, {:bound_to_different_user | :missing_user_id_field, map()}, Conn.t()} |
                                               {:error, {:strategy, any()}, Conn.t()} |
                                               {:error, map(), Conn.t()}
  def callback(conn, provider, params) do
    pow_config                  = fetch_pow_config(conn)
    user                        = Pow.Plug.current_user(conn)
    {strategy, provider_config} = get_provider_config(conn, provider)

    provider_config
    |> strategy.callback(conn, params)
    |> parse_callback_response()
    |> get_or_create_by_identity(provider, user, pow_config)
  end

  defp parse_callback_response({:ok, %{user: params, conn: conn}}) do
    conn = Conn.put_private(conn, :pow_assent_params, params)

    {:ok, conn}
  end
  defp parse_callback_response({:error, %{error: error, conn: conn}}) do
    {:error, {:strategy, error}, conn}
  end

  defp get_or_create_by_identity({:ok, conn}, provider, nil, config) do
    params = conn.private[:pow_assent_params]
    uid    = params["uid"]

    provider
    |> Operations.get_user_by_provider_uid(uid, config)
    |> case do
      nil  -> create_user(conn, provider, params, %{})
      user -> {:ok, user, get_mod(config).do_create(conn, user, config)}
    end
  end
  defp get_or_create_by_identity({:ok, conn}, provider, user, config) do
    params = conn.private[:pow_assent_params]
    uid    = params["uid"]

    user
    |> Operations.create(provider, uid, config)
    |> case do
      {:ok, _user_identity} -> {:ok, user, conn}
      {:error, changeset}   -> {:error, changeset, conn}
    end
  end
  defp get_or_create_by_identity({:error, error, conn}, _provider, _config, _user) do
    {:error, error, conn}
  end

  @doc """
  Create a user with user identity.
  """
  @spec create_user(Conn.t(), binary(), map(), map()) :: {:ok, map(), Conn.t()} | {:error, map(), Conn.t()}
  def create_user(conn, provider, params, user_id_params) do
    config = fetch_pow_config(conn)
    uid    = params["uid"]

    provider
    |> Operations.create_user(uid, params, user_id_params, config)
    |> case do
      {:ok, user}         -> {:ok, {:new, user}, get_mod(config).do_create(conn, user, config)}
      {:error, changeset} -> {:error, changeset, conn}
    end
  end

  @doc """
  Deletes the associated user identity for the current user and strategy.
  """
  @spec delete_identity(Conn.t(), binary()) :: {:ok, map(), Conn.t()} | {:error, any(), Conn.t()}
  def delete_identity(conn, provider) do
    config = fetch_pow_config(conn)

    conn
    |> Pow.Plug.current_user()
    |> Operations.delete(provider, config)
    |> case do
      {:ok, results}  -> {:ok, results, conn}
      {:error, error} -> {:error, error, conn}
    end
  end

  @doc """
  Lists associated strategy providers for the user.
  """
  @spec providers_for_current_user(Conn.t()) :: [atom()]
  def providers_for_current_user(conn) do
    config = fetch_pow_config(conn)

    conn
    |> Pow.Plug.current_user()
    |> get_all_providers_for_user(config)
    |> Enum.map(&String.to_atom(&1.provider))
  end

  defp get_all_providers_for_user(nil, _config), do: []
  defp get_all_providers_for_user(user, config), do: Operations.all(user, config)

  @doc """
  Lists available strategy providers for connection.
  """
  @spec available_providers(Conn.t()) :: [atom()]
  def available_providers(conn) do
    conn
    |> fetch_config()
    |> Config.get_providers()
    |> Keyword.keys()
  end

  defp get_provider_config(conn, provider) do
    provider = String.to_atom(provider)
    config   =
      conn
      |> fetch_config()
      |> Config.get_provider_config(provider)

    strategy        = config[:strategy]
    provider_config = Keyword.delete(config, :strategy)

    {strategy, provider_config}
  end

  defp fetch_config(conn) do
    conn
    |> fetch_pow_config()
    |> Config.env_config()
  end

  defp fetch_pow_config(conn) do
    Pow.Plug.fetch_config(conn)
  end

  defp get_mod(config), do: config[:mod]
end

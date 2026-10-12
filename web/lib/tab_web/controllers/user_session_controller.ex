defmodule TabWeb.UserSessionController do
  use TabWeb, :controller

  alias Tab.Accounts
  alias TabWeb.UserAuth

  # First sign-in: ask for a display name, then carry on to wherever they were headed
  # (an invite link, usually).
  def create(conn, %{"_action" => "confirmed"} = params) do
    next = get_session(conn, :user_return_to)
    welcome = if next, do: ~p"/welcome?#{[next: next]}", else: ~p"/welcome"

    conn
    |> put_session(:user_return_to, welcome)
    |> create(params, "You're in.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back.")
  end

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      _ ->
        conn
        |> put_flash(
          :error,
          "That sign-in link has expired or was already used. Ask for a new one below."
        )
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # email + password login
  defp create(conn, %{"user" => user_params}, info) do
    %{"email" => email, "password" => password} = user_params

    if user = Accounts.get_user_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, info)
      |> UserAuth.log_in_user(user, user_params)
    else
      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, "That email and password don't match.")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)
    {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

    # disconnect all existing LiveViews with old sessions
    UserAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:user_return_to, ~p"/users/settings")
    |> create(params, "Password saved.")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Signed out.")
    |> UserAuth.log_out_user()
  end
end

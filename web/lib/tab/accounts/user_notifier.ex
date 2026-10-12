defmodule Tab.Accounts.UserNotifier do
  import Swoosh.Email

  alias Tab.Mailer
  alias Tab.Accounts.User

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(Tab.Mailer.from())
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Confirm your new email for Tab", """
    To use this address for Tab, open this link:

    #{url}

    If you didn't ask to change your email, ignore this and nothing changes.
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Your link to sign in to Tab", """
    Open this link to sign in to Tab. It works once, for 15 minutes:

    #{url}

    If you didn't ask to sign in, ignore this. Nobody gets in without the link.
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Your link to start using Tab", """
    Open this link to finish making your Tab account. It works once, for 15 minutes:

    #{url}

    If you didn't ask for this, ignore it. Nobody can use the account without the link.
    """)
  end
end

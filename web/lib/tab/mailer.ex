defmodule Tab.Mailer do
  @moduledoc """
  Sends mail through whichever provider `config/runtime.exs` picked: Resend,
  SMTP, or (with neither) the log.
  """
  use Swoosh.Mailer, otp_app: :tab

  require Logger

  @doc "Who Tab's mail comes from: `TAB_MAIL_FROM`, or `tab@` the app's host."
  def from, do: Application.get_env(:tab, :mail_from, {"Tab", "tab@localhost"})

  @doc "True when mail only goes to the log (no provider set up)."
  def log_only? do
    Application.get_env(:tab, __MODULE__)[:adapter] == Swoosh.Adapters.Logger
  end

  @doc "Says so at boot when no mail provider is set up, and what to do about it."
  def warn_if_log_only do
    if log_only?() do
      Logger.warning("""
      No mail provider is set up, so Tab writes emails to this log instead of \
      sending them. Sign-in links appear here; copy one into your browser to sign in. \
      To send real mail, set RESEND_API_KEY, or SMTP_HOST (with SMTP_PORT, \
      SMTP_USERNAME, SMTP_PASSWORD).\
      """)
    end

    :ok
  end
end

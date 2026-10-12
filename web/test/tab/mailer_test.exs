defmodule Tab.MailerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup do
    original = Application.get_env(:tab, Tab.Mailer)
    on_exit(fn -> Application.put_env(:tab, Tab.Mailer, original) end)
  end

  test "with no provider set up, mail goes to the log and boot says how to fix it" do
    Application.put_env(:tab, Tab.Mailer,
      adapter: Swoosh.Adapters.Logger,
      log_full_email: true,
      level: :warning
    )

    assert Tab.Mailer.log_only?()

    log = capture_log(fn -> Tab.Mailer.warn_if_log_only() end)
    assert log =~ "Sign-in links appear here"
    assert log =~ "RESEND_API_KEY"
  end

  test "a sign-in email written to the log includes the link" do
    Application.put_env(:tab, Tab.Mailer,
      adapter: Swoosh.Adapters.Logger,
      log_full_email: true,
      level: :warning
    )

    email =
      Swoosh.Email.new(to: "a@example.com", from: Tab.Mailer.from(), subject: "Sign in")
      |> Swoosh.Email.text_body("https://tab.example/users/log-in/TOKEN")

    log = capture_log(fn -> {:ok, _} = Tab.Mailer.deliver(email) end)
    assert log =~ "https://tab.example/users/log-in/TOKEN"
  end

  test "with a provider, boot stays quiet" do
    Application.put_env(:tab, Tab.Mailer, adapter: Swoosh.Adapters.Test)
    refute Tab.Mailer.log_only?()
    assert capture_log(fn -> Tab.Mailer.warn_if_log_only() end) == ""
  end
end

defmodule Tabletop.Accounts.UserNotifier do
  import Swoosh.Email

  require Logger

  alias Tabletop.Mailer

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    config = Application.fetch_env!(:tabletop, Tabletop.Mailer)
    from = {Keyword.fetch!(config, :from_name), Keyword.fetch!(config, :from_email)}

    email =
      new()
      |> to(recipient)
      |> from(from)
      |> subject(subject)
      |> text_body(body)

    case Mailer.deliver(email) do
      {:ok, _metadata} ->
        {:ok, email}

      {:error, reason} ->
        Logger.error(
          "Email delivery failed: subject=#{inspect(subject)} from=#{inspect(from)} " <>
            "reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Deliver instructions to confirm a user's email address.
  """
  def deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.name},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to reset a user's password.
  """
  def deliver_reset_password_instructions(user, url) do
    deliver(user.email, "Reset password instructions", """

    ==============================

    Hi #{user.name},

    You can reset your password by visiting the URL below:

    #{url}

    This link expires in 24 hours.

    If you didn't request this change, please ignore this. Your password has
    not changed.

    ==============================
    """)
  end
end

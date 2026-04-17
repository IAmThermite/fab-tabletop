defmodule Tabletop.Accounts.UserNotifier do
  import Swoosh.Email

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

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
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
end

defmodule TabletopWeb.UserLive.ConfirmationPending do
  use TabletopWeb, :live_view

  alias Tabletop.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm text-center space-y-6">
        <.header>
          Thanks for registering!
          <:subtitle>
            We've sent a confirmation email to <strong>{@email}</strong>.
            Please check your inbox and click the link to verify your account.
          </:subtitle>
        </.header>

        <div class="border border-zinc-200 dark:border-zinc-700 rounded-lg p-6 space-y-4">
          <p class="text-sm text-zinc-600 dark:text-zinc-400">
            Didn't receive the email? Check your spam folder or resend it.
          </p>
          <button phx-click="resend" class="btn btn-primary btn-sm">
            Resend Confirmation Email
          </button>
        </div>

        <p class="text-sm text-zinc-500">
          Already confirmed?
          <.link navigate={~p"/users/log-in"} class="font-semibold text-brand hover:underline">
            Log in
          </.link>
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email = Phoenix.Flash.get(socket.assigns.flash, :email)

    if is_nil(email) do
      {:ok, redirect(socket, to: ~p"/users/log-in")}
    else
      {:ok, assign(socket, :email, email)}
    end
  end

  @impl true
  def handle_event("resend", _params, socket) do
    user = Accounts.get_user_by_email(socket.assigns.email)

    if user && is_nil(user.confirmed_at) do
      Accounts.deliver_user_confirmation_instructions(
        user,
        &url(~p"/users/confirm/#{&1}")
      )
    end

    {:noreply, put_flash(socket, :info, "If your email is in our system and unconfirmed, you will receive a confirmation email shortly.")}
  end
end

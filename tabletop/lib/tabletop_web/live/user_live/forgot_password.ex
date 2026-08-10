defmodule TabletopWeb.UserLive.ForgotPassword do
  use TabletopWeb, :live_view

  alias Tabletop.Accounts

  # Deliberately the same whether or not the address is registered — anything
  # more specific would let a visitor enumerate accounts from this form.
  @confirmation "If your email is in our system, you will receive instructions to reset your password shortly."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      system_announcement={@system_announcement}
    >
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            Forgot your password?
            <:subtitle>We'll email you a link to choose a new one.</:subtitle>
          </.header>
        </div>

        <.form for={@form} id="forgot_password_form" phx-submit="send_instructions">
          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="email"
            required
            phx-mounted={JS.focus()}
          />
          <.button phx-disable-with="Sending..." class="btn btn-primary w-full">
            Send reset instructions
          </.button>
        </.form>

        <p class="text-center text-sm mt-4">
          <.link navigate={~p"/users/log-in"} class="font-semibold text-brand hover:underline">
            Log in
          </.link>
          |
          <.link navigate={~p"/users/register"} class="font-semibold text-brand hover:underline">
            Register
          </.link>
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email = Phoenix.Flash.get(socket.assigns.flash, :email)

    {:ok, assign(socket, form: to_form(%{"email" => email}, as: "user"))}
  end

  @impl true
  def handle_event("send_instructions", %{"user" => %{"email" => email}}, socket)
      when is_binary(email) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_user_reset_password_instructions(
        user,
        &url(~p"/users/reset-password/#{&1}")
      )
    end

    {:noreply,
     socket
     |> put_flash(:info, @confirmation)
     |> redirect(to: ~p"/users/log-in")}
  end
end

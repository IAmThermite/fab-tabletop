defmodule TabletopWeb.UserLive.ResetPassword do
  use TabletopWeb, :live_view

  alias Tabletop.Accounts
  alias Tabletop.Accounts.User

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
            Choose a new password
            <:subtitle>
              Resetting your password signs you out everywhere else.
            </:subtitle>
          </.header>
        </div>

        <.form
          for={@form}
          id="reset_password_form"
          phx-change="validate"
          phx-submit="reset_password"
        >
          <.input
            field={@form[:password]}
            type="password"
            label="New password"
            autocomplete="new-password"
            required
            minlength={User.min_password_length()}
            phx-mounted={JS.focus()}
          />
          <p class="text-sm text-zinc-500 mt-1">
            At least {User.min_password_length()} characters.
          </p>
          <.input
            field={@form[:password_confirmation]}
            type="password"
            label="Confirm new password"
            autocomplete="new-password"
            required
          />
          <.button phx-disable-with="Resetting..." class="btn btn-primary w-full">
            Reset password
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
  def mount(%{"token" => token}, _session, socket) do
    case Accounts.get_user_by_reset_password_token(token) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Reset password link is invalid or it has expired.")
         |> redirect(to: ~p"/users/reset-password")}

      user ->
        # The token is re-verified on the connected mount, so a link that
        # expires between the two renders can't be used.
        {:ok,
         socket
         |> assign(:user, user)
         |> assign_form(Accounts.change_user_password(user, %{}, hash_password: false))}
    end
  end

  @impl true
  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      Accounts.change_user_password(socket.assigns.user, user_params, hash_password: false)

    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("reset_password", %{"user" => user_params}, socket) do
    case Accounts.reset_user_password(socket.assigns.user, user_params) do
      {:ok, {_user, expired_tokens}} ->
        # Whoever prompted the reset may already be sitting in a session.
        TabletopWeb.UserAuth.disconnect_sessions(expired_tokens)

        {:noreply,
         socket
         |> put_flash(:info, "Password reset successfully. You can now log in.")
         |> redirect(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: "user"))
  end
end

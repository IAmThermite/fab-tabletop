defmodule TabletopWeb.UserLive.Registration do
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
            Register for an account
            <:subtitle>
              Already registered?
              <.link navigate={~p"/users/log-in"} class="font-semibold text-brand hover:underline">
                Log in
              </.link>
              to your account now.
            </:subtitle>
          </.header>
        </div>

        <.form for={@form} id="registration_form" phx-submit="save" phx-change="validate">
          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="email"
            required
            phx-mounted={JS.focus()}
          />

          <.input
            field={@form[:name]}
            type="text"
            label="Username"
            autocomplete="username"
            required
            phx-mounted={JS.focus()}
          />

          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="new-password"
            required
            minlength={User.min_password_length()}
            phx-mounted={JS.focus()}
          />
          <p class="text-sm text-zinc-500 mt-1">
            At least {User.min_password_length()} characters.
          </p>

          <.button phx-disable-with="Creating account..." class="btn btn-primary w-full">
            Create an account
          </.button>

          <p class="text-sm text-zinc-500 mt-3 text-center">
            By creating an account you agree to our <.link
              navigate={~p"/terms"}
              class="link link-hover font-semibold"
            >
              Terms of Service
            </.link>,
            <.link navigate={~p"/code-of-conduct"} class="link link-hover font-semibold">
              Code of Conduct
            </.link>
            and <.link navigate={~p"/privacy"} class="link link-hover font-semibold">
              Privacy Policy
            </.link>.
          </p>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: TabletopWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.User.changeset(%User{}, %{})

    {:ok, assign_form(socket, changeset), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        Accounts.deliver_user_confirmation_instructions(
          user,
          &url(~p"/users/confirm/#{&1}")
        )

        {:noreply,
         socket
         |> put_flash(:email, user.email)
         |> push_navigate(to: ~p"/users/confirmation-pending")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.User.changeset(%User{}, user_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end

defmodule TabletopWeb.UserLive.Settings do
  use TabletopWeb, :live_view

  on_mount({TabletopWeb.UserAuth, :require_authenticated})

  alias Tabletop.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="text-center">
        <.link navigate={~p"/camera-setup"} class="btn btn-primary">
          Camera Setup
        </.link>
      </div>

      <hr />

      <div class="text-center">
        <.header>
          Account Settings
        </.header>
      </div>

      <.form
        for={@password_form}
        id="password_form"
        action={~p"/users/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
      >
        <input
          name={@password_form[:email].name}
          type="hidden"
          id="hidden_user_email"
          autocomplete="username"
          value={@current_email}
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label="New password"
          autocomplete="new-password"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          autocomplete="new-password"
        />
        <.button variant="primary" phx-disable-with="Saving...">
          Save Password
        </.button>
      </.form>

      <hr class="my-8" />

      <div class="text-center">
        <.header>Preferences</.header>
      </div>

      <.form
        for={@language_form}
        id="language_form"
        phx-change="validate_language"
        phx-submit="update_language"
      >
        <.input
          field={@language_form[:language]}
          type="select"
          label="Preferred language"
          prompt="No preference"
          options={Tabletop.Languages.options()}
        />
        <p class="text-sm text-zinc-500 mt-1">
          When set, new games you create default to this language.
        </p>
        <.button variant="primary" phx-disable-with="Saving...">
          Save Preferences
        </.button>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:language_form, to_form(Accounts.change_user_language(user)))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.User.changeset(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_language", %{"user" => user_params}, socket) do
    language_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_language(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, language_form: language_form)}
  end

  def handle_event("update_language", %{"user" => user_params}, socket) do
    case Accounts.update_user_language(socket.assigns.current_scope.user, user_params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Preferences updated")
         |> assign(:language_form, to_form(Accounts.change_user_language(user)))}

      {:error, changeset} ->
        {:noreply, assign(socket, language_form: to_form(changeset, action: :insert))}
    end
  end
end

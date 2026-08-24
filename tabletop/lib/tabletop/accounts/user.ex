defmodule Tabletop.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  # Minimum password length, enforced on registration, password change and
  # password reset — everything funnels through `validate_password/2`.
  @min_password_length 4

  @doc "Minimum number of characters a password must have."
  def min_password_length, do: @min_password_length

  schema "users" do
    field(:email, :string, writable: :insert)
    field(:password, :string, virtual: true, redact: true)
    field(:hashed_password, :string, redact: true)
    field(:confirmed_at, :utc_datetime)
    field(:authenticated_at, :utc_datetime, virtual: true)
    field(:name, :string)
    field(:language, Ecto.Enum, values: Tabletop.Languages.keys())

    timestamps(type: :utc_datetime)
  end

  @doc """
  A changeset for the user's optional preferred language. A blank value clears
  the preference (stored as `nil`). `Ecto.Enum` rejects any non-blank value
  outside the allowed set, so no extra inclusion check is needed.
  """
  def language_changeset(user, attrs) do
    cast(user, attrs, [:language])
  end

  @doc """
  Registration changeset.

  Email and username are both checked for uniqueness before the insert, so the
  form can report a clash on the field that caused it; the `unique_constraint/2`
  calls catch the race between that check and the insert.
  """
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password, :name])
    |> validate_required([:email, :password, :name])
    |> validate_email()
    |> validate_password(hash_password: true)
    |> unsafe_validate_unique(:name, Tabletop.Repo)
    |> unique_constraint(:name)
    |> unique_constraint(:email)
  end

  defp validate_email(changeset) do
    changeset
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:email, Tabletop.Repo)
  end

  @doc """
  A user changeset for changing the password.

  It is important to validate the length of the password, as long passwords may
  be very expensive to hash for certain algorithms.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: @min_password_length)
    # Bcrypt only reads the first 72 bytes, so reject longer passwords rather
    # than silently truncating them. Both length checks run before hashing so
    # the LiveView (`hash_password: false`) surfaces them while typing.
    |> validate_length(:password, max: 72, count: :bytes)
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # Hashing could be done with `Ecto.Changeset.prepare_changes/2`, but that
      # would keep the database transaction open longer and hurt performance.
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(user) do
    now = DateTime.utc_now(:second)
    change(user, confirmed_at: now)
  end

  @doc """
  Verifies the password.

  If there is no user or the user doesn't have a password, we call
  `Bcrypt.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(%Tabletop.Accounts.User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end
end

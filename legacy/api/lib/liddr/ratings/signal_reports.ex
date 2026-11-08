defmodule Liddr.Ratings.SignalReports do
  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Accounts.UserRole
  alias Liddr.Moderation
  alias Liddr.Moderation.Report
  alias Liddr.Moderation.ReportCategory
  alias Liddr.Repo

  @open_statuses ~w(submitted triaged under_review)
  @system_reporter_email "system+moderation@liddr.local"

  def create_system_report(attrs) do
    now = Map.fetch!(attrs, :now)
    reported_user_id = Map.fetch!(attrs, :reported_user_id)
    context_reference = Map.fetch!(attrs, :context_reference)
    description = Map.fetch!(attrs, :description)
    severity_level = Map.fetch!(attrs, :severity_level)
    incident_type = Map.get(attrs, :incident_type, "conduct")
    metadata = Map.get(attrs, :metadata, %{})
    cooldown_days = Map.get(attrs, :cooldown_days, 7)
    category_candidates = List.wrap(Map.get(attrs, :category_candidates, []))

    if signal_report_exists?(reported_user_id, context_reference, now, cooldown_days) do
      {:ok, :signal_already_open}
    else
      with {:ok, category_slug} <- resolve_category_slug(category_candidates),
           {:ok, reporter_user_id} <- resolve_system_reporter_user_id(reported_user_id, now),
           {:ok, _report} <-
             Moderation.submit_report(%{
               "reporter_user_id" => reporter_user_id,
               "reported_user_id" => reported_user_id,
               "category_slug" => category_slug,
               "source" => "system",
               "incident_type" => incident_type,
               "context_type" => "profile",
               "context_reference" => context_reference,
               "severity_level" => severity_level,
               "description" => description,
               "metadata" => metadata
             }) do
        {:ok, :signal_created}
      else
        _error -> {:ok, :signal_create_skipped}
      end
    end
  end

  defp signal_report_exists?(reported_user_id, context_reference, now, cooldown_days) do
    cooldown_cutoff = DateTime.add(now, -cooldown_days * 86_400, :second)

    Repo.exists?(
      from r in Report,
        where:
          r.reported_user_id == ^reported_user_id and r.context_type == "profile" and
            r.context_reference == ^context_reference and
            (r.status in ^@open_statuses or r.inserted_at >= ^cooldown_cutoff)
    )
  end

  defp resolve_category_slug([]), do: {:error, :missing_signal_category}

  defp resolve_category_slug([slug | rest]) do
    if active_category_slug?(slug) do
      {:ok, slug}
    else
      resolve_category_slug(rest)
    end
  end

  defp active_category_slug?(slug) do
    Repo.exists?(from c in ReportCategory, where: c.slug == ^slug and c.is_active == true)
  end

  defp resolve_system_reporter_user_id(reported_user_id, now) do
    email = system_reporter_email(reported_user_id)

    case Repo.get_by(User, email: email) do
      %User{id: id} ->
        {:ok, id}

      nil ->
        %User{}
        |> User.registration_changeset(%{"email" => email})
        |> Repo.insert()
        |> case do
          {:ok, user} -> ensure_ops_role(user.id, now)
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  defp ensure_ops_role(user_id, now) do
    role =
      Repo.one(
        from ur in UserRole,
          where: ur.user_id == ^user_id and ur.role == "ops" and is_nil(ur.revoked_at),
          limit: 1
      ) || %UserRole{}

    role
    |> UserRole.create_changeset(%{
      "user_id" => user_id,
      "role" => "ops",
      "granted_at" => now
    })
    |> Repo.insert_or_update()
    |> case do
      {:ok, _} -> {:ok, user_id}
      {:error, _changeset} -> {:ok, user_id}
    end
  end

  defp system_reporter_email(reported_user_id) do
    case Repo.get_by(User, email: @system_reporter_email) do
      %User{id: ^reported_user_id} -> "system+moderation+#{reported_user_id}@liddr.local"
      _ -> @system_reporter_email
    end
  end
end

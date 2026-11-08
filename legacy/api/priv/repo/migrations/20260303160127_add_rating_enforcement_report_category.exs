defmodule Liddr.Repo.Migrations.AddRatingEnforcementReportCategory do
  use Ecto.Migration

  def change do
    execute(
      """
      INSERT INTO report_categories (
        slug,
        label,
        description,
        applies_to,
        severity_level_default,
        recommended_action,
        requires_immediate_attention,
        is_active,
        display_order,
        inserted_at,
        updated_at
      )
      VALUES (
        'rating_quality_risk',
        'Rating Quality Risk',
        'System-generated signal for sustained low ratings requiring human moderation review.',
        'both',
        3,
        'review',
        false,
        true,
        180,
        NOW(),
        NOW()
      )
      ON CONFLICT (slug) DO UPDATE SET
        label = EXCLUDED.label,
        description = EXCLUDED.description,
        applies_to = EXCLUDED.applies_to,
        severity_level_default = EXCLUDED.severity_level_default,
        recommended_action = EXCLUDED.recommended_action,
        requires_immediate_attention = EXCLUDED.requires_immediate_attention,
        is_active = EXCLUDED.is_active,
        display_order = EXCLUDED.display_order,
        updated_at = NOW()
      """,
      "DELETE FROM report_categories WHERE slug = 'rating_quality_risk'"
    )
  end
end

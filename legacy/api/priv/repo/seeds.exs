# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Liddr.Repo.insert!(%Liddr.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias Liddr.Repo

now = DateTime.utc_now() |> DateTime.truncate(:second)

categories = [
  %{
    slug: "motorbike",
    label: "Motorbike",
    capacity: 1,
    base_fee_kes: Decimal.new("20.00"),
    price_per_km_kes: Decimal.new("15.00"),
    price_per_min_kes: Decimal.new("3.00"),
    min_fare_kes: Decimal.new("120.00"),
    discount_percent: Decimal.new("15.00"),
    weekly_sub_kes: 10,
    is_active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "electric_motorbike",
    label: "Electric Motorbike",
    capacity: 1,
    base_fee_kes: Decimal.new("45.00"),
    price_per_km_kes: Decimal.new("15.00"),
    price_per_min_kes: Decimal.new("3.00"),
    min_fare_kes: Decimal.new("140.00"),
    discount_percent: Decimal.new("15.00"),
    weekly_sub_kes: 15,
    is_active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "basic",
    label: "Basic",
    capacity: 3,
    base_fee_kes: Decimal.new("55.00"),
    price_per_km_kes: Decimal.new("25.00"),
    price_per_min_kes: Decimal.new("5.00"),
    min_fare_kes: Decimal.new("230.00"),
    discount_percent: Decimal.new("15.00"),
    weekly_sub_kes: 20,
    is_active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "send",
    label: "Send",
    capacity: 0,
    base_fee_kes: Decimal.new("25.00"),
    price_per_km_kes: Decimal.new("16.00"),
    price_per_min_kes: Decimal.new("3.00"),
    min_fare_kes: Decimal.new("150.00"),
    discount_percent: Decimal.new("15.00"),
    weekly_sub_kes: 15,
    is_active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "comfort",
    label: "Comfort",
    capacity: 4,
    base_fee_kes: Decimal.new("95.00"),
    price_per_km_kes: Decimal.new("42.00"),
    price_per_min_kes: Decimal.new("11.00"),
    min_fare_kes: Decimal.new("390.00"),
    discount_percent: Decimal.new("15.00"),
    weekly_sub_kes: 25,
    is_active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "xl",
    label: "XL",
    capacity: 6,
    base_fee_kes: Decimal.new("140.00"),
    price_per_km_kes: Decimal.new("40.00"),
    price_per_min_kes: Decimal.new("16.00"),
    min_fare_kes: Decimal.new("470.00"),
    discount_percent: Decimal.new("15.00"),
    weekly_sub_kes: 30,
    is_active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "women_only",
    label: "Women Only",
    capacity: 3,
    base_fee_kes: Decimal.new("62.00"),
    price_per_km_kes: Decimal.new("32.00"),
    price_per_min_kes: Decimal.new("6.00"),
    min_fare_kes: Decimal.new("300.00"),
    discount_percent: Decimal.new("15.00"),
    weekly_sub_kes: 22,
    is_active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "green",
    label: "Green",
    capacity: 3,
    base_fee_kes: Decimal.new("60.00"),
    price_per_km_kes: Decimal.new("31.00"),
    price_per_min_kes: Decimal.new("6.00"),
    min_fare_kes: Decimal.new("290.00"),
    discount_percent: Decimal.new("15.00"),
    weekly_sub_kes: 20,
    is_active: true,
    inserted_at: now,
    updated_at: now
  }
]

Repo.insert_all(
  "vehicle_categories",
  categories,
  on_conflict:
    {:replace,
     [
       :label,
       :capacity,
       :base_fee_kes,
       :price_per_km_kes,
       :price_per_min_kes,
       :min_fare_kes,
       :discount_percent,
       :weekly_sub_kes,
       :is_active,
       :updated_at
     ]},
  conflict_target: [:slug]
)

verification_requirements = [
  %{
    document_type: "national_id_front",
    label: "National ID (Front)",
    required: true,
    requires_expiry: false,
    is_active: true,
    display_order: 10,
    inserted_at: now,
    updated_at: now
  },
  %{
    document_type: "national_id_back",
    label: "National ID (Back)",
    required: true,
    requires_expiry: false,
    is_active: true,
    display_order: 20,
    inserted_at: now,
    updated_at: now
  },
  %{
    document_type: "drivers_licence",
    label: "Driver's Licence",
    required: true,
    requires_expiry: true,
    is_active: true,
    display_order: 30,
    inserted_at: now,
    updated_at: now
  },
  %{
    document_type: "psv_badge",
    label: "PSV Badge",
    required: true,
    requires_expiry: true,
    is_active: true,
    display_order: 40,
    inserted_at: now,
    updated_at: now
  },
  %{
    document_type: "good_conduct_certificate",
    label: "Good Conduct Certificate",
    required: true,
    requires_expiry: true,
    is_active: true,
    display_order: 50,
    inserted_at: now,
    updated_at: now
  },
  %{
    document_type: "vehicle_logbook",
    label: "Vehicle Logbook",
    required: true,
    requires_expiry: false,
    is_active: true,
    display_order: 60,
    inserted_at: now,
    updated_at: now
  },
  %{
    document_type: "commercial_insurance",
    label: "Commercial Insurance Certificate",
    required: true,
    requires_expiry: true,
    is_active: true,
    display_order: 70,
    inserted_at: now,
    updated_at: now
  },
  %{
    document_type: "driver_selfie_liveness",
    label: "Driver Selfie (Liveness)",
    required: true,
    requires_expiry: false,
    is_active: true,
    display_order: 80,
    inserted_at: now,
    updated_at: now
  },
  %{
    document_type: "vehicle_photo_front",
    label: "Vehicle Photo (Front)",
    required: true,
    requires_expiry: false,
    is_active: true,
    display_order: 90,
    inserted_at: now,
    updated_at: now
  },
  %{
    document_type: "vehicle_photo_back",
    label: "Vehicle Photo (Back)",
    required: true,
    requires_expiry: false,
    is_active: true,
    display_order: 100,
    inserted_at: now,
    updated_at: now
  }
]

Repo.insert_all(
  "verification_requirements",
  verification_requirements,
  on_conflict:
    {:replace, [:label, :required, :requires_expiry, :is_active, :display_order, :updated_at]},
  conflict_target: [:document_type]
)

report_categories = [
  %{
    slug: "unsafe_driving",
    label: "Unsafe Driving",
    description: "Overspeeding, reckless overtaking, or dangerous road behavior.",
    applies_to: "driver",
    severity_level_default: 5,
    recommended_action: "temporary_suspension",
    requires_immediate_attention: true,
    is_active: true,
    display_order: 10,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "harassment_or_abuse",
    label: "Harassment or Abuse",
    description: "Threats, verbal abuse, intimidation, or hostile conduct.",
    applies_to: "both",
    severity_level_default: 5,
    recommended_action: "temporary_suspension",
    requires_immediate_attention: true,
    is_active: true,
    display_order: 20,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "sexual_misconduct",
    label: "Sexual Misconduct",
    description: "Sexual harassment, inappropriate comments, or sexual assault allegations.",
    applies_to: "both",
    severity_level_default: 5,
    recommended_action: "permanent_ban",
    requires_immediate_attention: true,
    is_active: true,
    display_order: 30,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "discrimination",
    label: "Discrimination",
    description:
      "Bias or refusal based on gender, disability, religion, race, or other protected traits.",
    applies_to: "both",
    severity_level_default: 5,
    recommended_action: "temporary_suspension",
    requires_immediate_attention: true,
    is_active: true,
    display_order: 40,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "violence_or_threat",
    label: "Violence or Threat",
    description: "Physical assault, attempted assault, or credible threat of violence.",
    applies_to: "both",
    severity_level_default: 5,
    recommended_action: "permanent_ban",
    requires_immediate_attention: true,
    is_active: true,
    display_order: 50,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "fraud_or_scam",
    label: "Fraud or Scam",
    description: "Fake trips, payment manipulation, or intentional financial deception.",
    applies_to: "both",
    severity_level_default: 4,
    recommended_action: "temporary_suspension",
    requires_immediate_attention: true,
    is_active: true,
    display_order: 60,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "payment_dispute",
    label: "Payment Dispute",
    description: "Fare disagreement, incorrect charge, or refusal to settle valid payment.",
    applies_to: "both",
    severity_level_default: 3,
    recommended_action: "review",
    requires_immediate_attention: false,
    is_active: true,
    display_order: 70,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "account_sharing_or_impersonation",
    label: "Account Sharing or Impersonation",
    description: "Using another person's account or failing identity consistency checks.",
    applies_to: "both",
    severity_level_default: 4,
    recommended_action: "temporary_suspension",
    requires_immediate_attention: true,
    is_active: true,
    display_order: 80,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "vehicle_condition_issue",
    label: "Vehicle Condition Issue",
    description: "Unsafe, unclean, or non-compliant vehicle condition.",
    applies_to: "driver",
    severity_level_default: 3,
    recommended_action: "warn",
    requires_immediate_attention: false,
    is_active: true,
    display_order: 90,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "document_or_eligibility_issue",
    label: "Document or Eligibility Issue",
    description: "Missing, expired, forged, or mismatched legal/compliance documents.",
    applies_to: "driver",
    severity_level_default: 4,
    recommended_action: "temporary_suspension",
    requires_immediate_attention: true,
    is_active: true,
    display_order: 100,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "intoxication_or_substance_use",
    label: "Intoxication or Substance Use",
    description: "Operating while intoxicated or under influence of illegal substances.",
    applies_to: "both",
    severity_level_default: 5,
    recommended_action: "permanent_ban",
    requires_immediate_attention: true,
    is_active: true,
    display_order: 110,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "cancellation_or_no_show_abuse",
    label: "Cancellation or No-show Abuse",
    description: "Repeated no-shows, abuse of cancellations, or intentional disruption.",
    applies_to: "both",
    severity_level_default: 2,
    recommended_action: "warn",
    requires_immediate_attention: false,
    is_active: true,
    display_order: 120,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "privacy_violation",
    label: "Privacy Violation",
    description: "Unauthorized sharing of personal data, photos, or contact details.",
    applies_to: "both",
    severity_level_default: 4,
    recommended_action: "temporary_suspension",
    requires_immediate_attention: true,
    is_active: true,
    display_order: 130,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "property_damage",
    label: "Property Damage",
    description: "Damage to rider or driver property during service.",
    applies_to: "both",
    severity_level_default: 3,
    recommended_action: "review",
    requires_immediate_attention: false,
    is_active: true,
    display_order: 140,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "theft_or_lost_property_misconduct",
    label: "Theft or Lost Property Misconduct",
    description: "Alleged theft, withholding returned property, or misuse of found items.",
    applies_to: "both",
    severity_level_default: 4,
    recommended_action: "temporary_suspension",
    requires_immediate_attention: true,
    is_active: true,
    display_order: 150,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "child_safety_violation",
    label: "Child Safety Violation",
    description: "Breach of child safety requirements during transport or pickup.",
    applies_to: "both",
    severity_level_default: 5,
    recommended_action: "temporary_suspension",
    requires_immediate_attention: true,
    is_active: true,
    display_order: 160,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "off_platform_solicitation",
    label: "Off-platform Solicitation",
    description: "Pressuring users to move transactions outside the platform.",
    applies_to: "both",
    severity_level_default: 3,
    recommended_action: "warn",
    requires_immediate_attention: false,
    is_active: true,
    display_order: 170,
    inserted_at: now,
    updated_at: now
  },
  %{
    slug: "other",
    label: "Other",
    description: "Issue not covered by predefined categories; requires manual triage.",
    applies_to: "both",
    severity_level_default: 2,
    recommended_action: "review",
    requires_immediate_attention: false,
    is_active: true,
    display_order: 999,
    inserted_at: now,
    updated_at: now
  }
]

Repo.insert_all(
  "report_categories",
  report_categories,
  on_conflict:
    {:replace,
     [
       :label,
       :description,
       :applies_to,
       :severity_level_default,
       :recommended_action,
       :requires_immediate_attention,
       :is_active,
       :display_order,
       :updated_at
     ]},
  conflict_target: [:slug]
)

prohibited_items = [
  %{
    keyword: "cash",
    severity: "block",
    message: "Cash delivery is not allowed for Send.",
    is_active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    keyword: "firearm",
    severity: "block",
    message: "Firearms are prohibited on the platform.",
    is_active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    keyword: "alcohol",
    severity: "block",
    message: "Alcohol delivery is not supported for Send.",
    is_active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    keyword: "jewellery",
    severity: "warn",
    message: "High-value items travel at sender liability.",
    is_active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    keyword: "electronics",
    severity: "warn",
    message: "Fragile electronics require careful packaging by sender.",
    is_active: true,
    inserted_at: now,
    updated_at: now
  }
]

Repo.insert_all(
  "prohibited_items",
  prohibited_items,
  on_conflict: {:replace, [:severity, :message, :is_active, :updated_at]},
  conflict_target: [:keyword]
)

SYSTEM DESIGN DOCUMENT
Liddr — Ride & Delivery Platform
Kenya Market | Version 1.3


1. Product Overview
Liddr is a multi-category ride-hailing and delivery platform for the Kenyan market. It covers motorbikes, electric motorbikes, small cars, and package delivery (Send). Drivers pay a flat weekly subscription to access the platform — no per-ride commission. Passengers use the app free of charge. Fares are dynamic, calculated in real time based on supply and demand within geographic zones.
Subscription pricing is proportional to earning potential per vehicle category. The higher the average fare a vehicle type commands, the higher the weekly subscription — ensuring the platform fee always represents a fair and small fraction of driver earnings.

Component	Description
Driver / Courier	Pays weekly subscription by vehicle category. Receives requests. Keeps 100% of every fare.
Passenger / Sender	Uses app for free. Pays driver directly via M-Pesa or cash.
Platform	Earns from driver subscriptions only. Provides matching, dynamic pricing, tracking, and verification.

1.1 Vehicle Categories — MVP Launch
Category	Passengers	Avg Fare Range	Weekly Sub	Notes
Motorbike	1	KES 200–500	KES 1,000	Standard boda boda
Electric Motorbike	1	KES 200–500	KES 1,000	Same tier as motorbike — same earning potential
Basic (small car)	3	KES 600–900	KES 2,000	Affordable 4-door car
Send (delivery)	0	KES 300–600	KES 1,500	Package delivery — no passenger

1.2 Vehicle Categories — Phase 2
Category	Passengers	Avg Fare Range	Weekly Sub	Notes
Comfort	4	KES 900–1,400	KES 2,500	Premium cars, top-rated drivers
XL	6	KES 1,200–1,800	KES 3,000	Large vehicles for groups
Women Only	3	KES 700–1,100	KES 2,000	Both driver and passenger must be female
Green (electric car)	3	KES 600–900	KES 2,000	Electric vehicles — eco category


2. Technology Stack
What runs today. AGENTS.md at the repository root holds the engineering rules, and each app's own files hold its setup.

Layer	Technology	Notes
API	Go, plain net/http	apps/api. The OpenAPI contract in packages/contract/openapi.yaml is the source of truth for every route.
Real-time	WebSockets (coder/websocket)	Live ride status, offers and driver location, published through Postgres notifications.
Database	PostgreSQL	pgx and sqlc; forward-only goose migrations applied as a deploy step. Live location and dispatch also run on Postgres.
Background jobs	In-process workers over Postgres	Offer expiry, dispatch, payment rechecks, reminders and retention, with their deadlines kept in Postgres.
Cache	Redis	Available but not used yet; Postgres stays the source of truth.
Mobile — Android	Kotlin, Jetpack Compose	apps/android. Maps SDK and Places (New) behind the liddr.mapsApiKey Gradle property.
Mobile — iOS	Swift	Not started.
Staff console	TanStack Start (React)	apps/ops. Runs beside the API on one origin; staff sign in with session cookies.
Maps & routing	Google Routes API	Fares and ETAs (computeRoutes).
Payments	Safaricom Daraja (M-Pesa)	STK push and its status query, plus Paybill (C2B) confirmations, built in-house.
SMS	Onfon Media	Sign-in codes.
Email	Resend	Email sign-in codes.
Push	Firebase Cloud Messaging (HTTP v1)	The API sends; the Android app does not receive yet.
Document storage	Cloudflare R2	Private bucket, short-lived signed links; uploads scanned by ClamAV before review.
Hosting (test)	Docker Compose behind a Cloudflare Tunnel	api-test.liddr.app and ops-test.liddr.app.

2.1 Repository Layout
One repository (a monorepo) with independent apps:
  apps/api        Go API (go.work at the root)
  apps/android    Kotlin Android app
  apps/ops        staff console
  packages/contract  the OpenAPI contract
  docs/           product rules and policies

The API was first built in Elixir/Phoenix and later rewritten in Go. The Elixir code was removed; the git tag legacy-elixir-final keeps its last version.

Environment Variables
Each app has its own configuration — never commit secrets to git.
apps/api/.env                 ← API settings; apps/api/.env.example lists and explains every one
apps/android: ~/.gradle/gradle.properties  ← liddr.mapsApiKey, kept out of the repository
apps/ops                      ← LIDDR_DOCUMENT_ORIGIN (see apps/ops/README.md)


3. High-Level Architecture
Note: sections 3 onward record the original design, written when the backend was Elixir/Phoenix (Channels, Presence, OTP, an umbrella app). The Go API in apps/api and the contract implement these ideas differently; where they differ, the code and contract are authoritative.
The system is built around two core services — Supply (drivers) and Demand (passengers) — connected by a central Dispatch (matching) engine. This mirrors Uber's DISCO architecture adapted for our scale and market. The real-time layer is handled entirely by Phoenix Channels and Presence — no external WebSocket infrastructure required.

3.1 Component Map
[ Passenger App — SwiftUI/Kotlin ]  ──►  [ Phoenix HTTP/WebSocket ]  ──►  [ liddr_rides ]
[ Driver App    — SwiftUI/Kotlin ]  ──►  [ Phoenix Channels        ]  ──►  [ liddr_location ]
                                                   │
                                        [ Phoenix Presence ]
                                        (online/offline tracking)
                                                   │
       ┌───────────────────────────────────────────┴──────────────────────────┐
[ liddr_dispatch ]  [ liddr_pricing ]  [ liddr_payments ]  [ liddr_ratings ]
       │
  ┌────┴─────┐
[ PostgreSQL ]  [ Redis ]

3.2 API Gateway
Single entry point for all client requests. Responsibilities:
•	JWT authentication — validates every request before routing
•	Rate limiting — prevents abuse, protects backend services
•	Request routing — directs traffic to the correct internal service
•	WAF (Web Application Firewall) — blocks suspicious IPs and bots

3.3 Core Applications (Elixir Umbrella — Modular Monolith)

Package	Responsibility
auth	Phone+OTP for drivers. Google Sign-In for passengers. JWT issuance and validation.
rides	Manages full ride and delivery lifecycle across all vehicle categories.
dispatch	Category-aware matching — filters driver pool by requested vehicle type before proximity ranking.
pricing	Dynamic fare calculation per category. Each category has its own base fee, price per km, and surge config.
location	GPS pings from all active drivers every 4 seconds. Writes to Redis keyed by driver ID and S2 cell.
payments	M-Pesa STK Push for passenger fares. Subscription billing per driver tier. Webhook handling.
notifications	FCM push and Africa's Talking SMS across all event types.
subscriptions	Weekly subscription lifecycle per driver — tier assignment, renewal, suspension, grace period.
categories	Vehicle category registry — defines capacity, fare config, subscription tier, and eligibility rules per category.
send	Delivery-specific flow — sender details, item description, recipient info, proof of delivery, prohibited items check.
women_only	Gender verification flag enforcement — only female-verified drivers visible to female-verified passengers in this category.
verification	KYC document pipeline, AI checks, human review queue, vehicle validation, continuous spot checks.


4. Data Flow: Full Ride Lifecycle
Step 1 — Passenger Opens App
•	App opens WebSocket connection to Location Service
•	Passenger's S2 cell ID is calculated from their GPS coordinates
•	Nearby available drivers fetched from Redis using cell ID — not PostgreSQL
•	Driver markers rendered on map in real time

Step 2 — Passenger Requests Ride
•	Passenger sets destination, confirms booking
•	Request sent via WebSocket to Demand Service
•	Demand Service calls Pricing Service with passenger cell ID
•	Pricing Service checks Redis: active drivers vs active requests in that zone
•	Surge multiplier calculated, fare estimated and returned to passenger
•	Passenger sees upfront fare and confirms

Step 3 — Dispatch Engine Activates
•	Ride record created in PostgreSQL with status: PENDING
•	Request pushed to Redis matching queue for that S2 zone
•	Dispatch Engine queries Redis for available drivers within radius
•	Drivers ranked by actual road ETA (not straight-line distance)
•	Ride request notification sent to closest driver first
•	Driver has 15 seconds to accept — timeout triggers next driver

Step 4 — Driver Accepts
•	Ride record updated in PostgreSQL: ACCEPTED
•	Both passenger and driver notified instantly via WebSocket
•	Passenger app begins showing driver's live location
•	Driver app receives navigation to pickup point

Step 5 — Ride In Progress
•	Driver app sends GPS coordinates every 4 seconds to Location Service
•	Coordinates written to Redis (not PostgreSQL — too many writes)
•	Passenger app receives driver location via WebSocket in real time
•	Ride Service monitors for unusual inactivity (driver went offline mid-ride)

Step 6 — Ride Completed
•	Driver marks ride complete
•	Payment Service triggers M-Pesa STK Push to passenger's phone
•	Ride record updated: COMPLETED, fare logged
•	Rating prompts sent to both driver and passenger
•	Driver earnings updated in dashboard


5. Geographic Indexing — Google S2 Library
The Earth is a sphere. Raw latitude/longitude alone is inefficient for spatial queries at scale. The Google S2 library solves this by dividing the Earth's surface into a hierarchy of cells, each with a unique 64-bit integer ID.

5.1 How S2 Works For This System
•	Nairobi is divided into S2 cells at an appropriate resolution (roughly 1–3km per cell)
•	Each driver's GPS location is converted to an S2 cell ID on every location ping
•	Cell ID is used as a shard key — driver data is stored under their current cell ID in Redis
•	When a passenger requests a ride, their cell ID is calculated
•	Dispatch Engine draws a circle around the passenger's cell and queries all cells within that radius
•	S2 returns all cell IDs within the radius — these are queried in Redis for available drivers

5.2 Why This Is Efficient
Instead of calculating distance from every driver to every passenger (expensive), the system only looks at drivers already indexed in nearby cells. At 5,000 active drivers in Nairobi, this reduces the comparison set from thousands to typically 5–20 relevant drivers per query.


6. Real-Time Location Architecture
This is the most write-intensive part of the system and must be designed carefully from day one.

6.1 Write Path (Driver → Server)
•	Driver app sends GPS ping every 4 seconds via WebSocket
•	Location Service receives ping, calculates S2 cell ID
•	Writes to Redis: driver:{id}:location → { lat, lng, cell_id, timestamp }
•	Updates zone supply count: zone:{cell_id}:supply → increment/decrement
•	Every 5 minutes, batch writes to PostgreSQL for historical records and analytics

6.2 Read Path (Passenger App)
•	Passenger app reads driver positions via WebSocket — server pushes updates
•	Server reads from Redis only — never PostgreSQL for live location
•	Redis returns positions in under 1ms at any scale

6.3 Scale Estimate
Active Drivers	Pings/Second	Redis Writes/Second	Notes
1,000	250	250	Trivial load, single Redis instance handles easily
5,000	1,250	1,250	Still comfortable, monitor Redis memory usage
20,000	5,000	5,000	Redis Cluster needed, consider write batching
50,000+	12,500	12,500	Redis Sentinel + Cluster, regional sharding by S2 zone


7. Dispatch Engine (DISCO)
The Dispatch Engine is the heart of the system. Its three objectives are: minimize driver travel to pickup, minimize passenger wait time, and find the lowest overall ETA.

7.1 Matching Algorithm
•	Passenger request arrives with their S2 cell ID
•	Dispatch Engine queries Redis for all available drivers in nearby cells
•	For each candidate driver, road ETA is calculated via Google Directions API
•	Drivers are sorted by ETA ascending
•	Ride offer sent to the driver with lowest ETA
•	15-second accept window — if no response, move to next driver
•	Repeat until accepted or no drivers available

7.2 Race Condition Prevention
Multiple passengers could match to the same driver simultaneously. This is prevented by:
•	Redis atomic operations (SETNX) to lock a driver to one pending offer at a time
•	Driver status transitions are transactional — AVAILABLE → OFFER_SENT → ACCEPTED
•	If a driver declines or times out, status returns to AVAILABLE atomically

7.3 Fallback: No Drivers Available
•	Passenger notified honestly with estimated wait time based on zone data
•	Request held in queue for up to 3 minutes before expiry
•	System monitors for newly available drivers and retries automatically


8. Dynamic Pricing Engine
Fares are calculated in real time based on supply and demand within each S2 zone. The algorithm runs every time a passenger requests a ride.

8.1 Fare Formula
base_fare = base_fee + (price_per_km × distance_km)
supply_demand_ratio = available_drivers / active_requests
surge_multiplier = f(supply_demand_ratio)
final_fare = base_fare × surge_multiplier

8.2 Surge Multiplier Table
Supply/Demand Ratio	Surge Multiplier	Meaning
≥ 1.0	1.0×	Normal — sufficient supply
0.8 – 1.0	1.2×	Slightly constrained supply
0.5 – 0.8	1.5×	High demand, limited drivers
< 0.5	2.0×	Very high demand, minimal supply

8.3 Guardrails
•	Maximum surge cap: 3.0× — above this, passengers feel exploited
•	Surge shown to passenger before booking — always transparent
•	Gradual price reduction when demand drops — sudden drops feel unfair to drivers already en route
•	Zone-isolated — each S2 cell zone calculates independently

8.4 External Factors (Phase 2)
•	Time of day — rush hours 7–9am and 5–8pm weighted in multiplier
•	Weather — rain events detected via API, surge pre-applied
•	Local events — operator-configured surge for matches, concerts
•	Historical patterns — recurring Monday Westlands surge pre-empted proactively


9. Database Design
9.1 PostgreSQL — Persistent Tables
Schema is designed to support all vehicle categories from day one. Category-awareness is baked into the core tables rather than bolted on later.

Table	Key Columns	Purpose
users	id, phone, google_id, role (driver|passenger), gender, rating, created_at	All users. google_id for passengers using Google Sign-In. Gender field for Women Only enforcement.
vehicle_categories	id, slug (motorbike|electric_motorbike|basic|send|comfort|xl|women_only|green), label, capacity, base_fee, price_per_km, weekly_sub_kes, is_active	Category registry — single source of truth for all fare and subscription config.
drivers	user_id, license_no, plate_no, vehicle_category_id, vehicle_year, subscription_status, is_available, gender_verified	Driver profile. vehicle_category_id links to vehicle_categories. gender_verified flag for Women Only.
rides	id, type (ride|delivery), passenger_id, driver_id, vehicle_category_id, status, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng, quoted_fare, final_fare, distance_km, started_at, completed_at	Unified ride and delivery record. type field distinguishes Send from rides.
deliveries	id, ride_id, sender_id, recipient_name, recipient_phone, item_description, item_size, payer (sender|recipient), payment_timing (before|after), proof_of_delivery_photo, delivery_status	Send-specific metadata attached to a ride record.
payments	id, ride_id, payer_id, amount, method (mpesa|cash), status, mpesa_reference, created_at	Payment per ride or delivery.
subscriptions	id, driver_id, vehicle_category_id, week_start, week_end, amount_kes, status, payment_id	Weekly subscription. amount_kes pulled from vehicle_categories at time of payment.
ratings	id, ride_id, rated_by, rated_user, score, comment	Post-ride ratings both directions.
zone_pricing	id, s2_cell_id, vehicle_category_id, base_fee_override, price_per_km_override, max_surge	Per-zone pricing overrides per category. Falls back to vehicle_categories defaults if no override.
prohibited_items	id, keyword, severity (warn|block)	Blocked item descriptions for Send — checked against delivery item_description at booking.

9.2 Redis — Ephemeral / Real-Time Keys
Category is embedded in supply keys so the dispatch engine can query drivers by type without scanning all available drivers.

Key Pattern	Value	TTL
driver:{id}:location	{ lat, lng, cell_id, category_slug, timestamp }	30 seconds — stale if not refreshed
driver:{id}:status	AVAILABLE | OFFER_SENT | ON_RIDE | OFFLINE	None — updated by events
zone:{cell_id}:supply:{category_slug}	Integer count of available drivers of that category in that zone	Updated on driver status change
zone:{cell_id}:demand:{category_slug}	Integer count of active requests for that category in that zone	Updated on request events
ride:{id}:offer_lock	driver_id currently being offered ride	15 seconds — TTL enforces timeout
session:{user_id}	JWT token	Matches token expiry
women_only:drivers:{cell_id}	Set of available female-verified driver IDs in that zone	Updated on driver status change


10. Subscription Management
Driver subscriptions are the sole revenue source. Subscription amount is determined by the driver's registered vehicle category — pulled from the vehicle_categories table at the time of payment. This means pricing can be updated centrally without any app changes.

10.1 Subscription Tiers
Category	Weekly Sub	Monthly Equivalent	Earning Potential (est.)
Motorbike	KES 1,000	KES 4,000	KES 50,000–80,000/month
Electric Motorbike	KES 1,000	KES 4,000	KES 50,000–80,000/month
Send (delivery)	KES 1,500	KES 6,000	KES 60,000–90,000/month
Basic (small car)	KES 2,000	KES 8,000	KES 90,000–140,000/month
Comfort (Phase 2)	KES 2,500	KES 10,000	KES 120,000–180,000/month
XL (Phase 2)	KES 3,000	KES 12,000	KES 150,000–220,000/month

10.2 Subscription Lifecycle
•	Driver registers and selects vehicle category — subscription amount determined automatically from vehicle_categories table
•	Driver completes KYC verification — subscription payment only unlocked after verification approval
•	Driver pays via M-Pesa STK Push — amount pulled dynamically from category config
•	Daraja API processes payment → webhook hits payments package
•	Subscription record created in PostgreSQL with vehicle_category_id, amount_kes, week_start, week_end
•	Driver account activated — can go online and receive requests in their category
•	Every Sunday at 8pm: automated job queries all subscriptions expiring within 24 hours
•	Renewal reminder sent via FCM push and SMS with exact amount due
•	Monday 6am: expired subscriptions suspended — driver goes offline automatically
•	6-hour grace window before hard suspension — catches late payers
•	Suspended driver sees one-tap renewal prompt on app open

10.3 Category Change
•	Driver can apply to change vehicle category — e.g. upgrades from motorbike to basic car
•	Category change requires new vehicle documents to be submitted and verified
•	New subscription tier applies from the next billing week — not mid-week
•	Old category subscription remains active until end of current week

10.4 Failure Handling
•	M-Pesa STK Push timeout — never assume failed, poll Daraja API transaction status endpoint
•	Idempotency key per payment attempt — prevents duplicate charges
•	If driver pays twice in same week — second payment credited as next week subscription automatically


11. Notification Architecture
Kenya has variable internet connectivity. A two-channel notification strategy ensures critical messages are always delivered.

Event	Channel	Fallback
New ride request	WebSocket (real-time)	FCM push if app backgrounded
Driver accepted	WebSocket	FCM push
Driver arriving	FCM push	SMS via Africa's Talking
Ride completed	FCM push	SMS
Subscription expiring	FCM push	SMS
Subscription suspended	FCM push + SMS	No fallback — both sent simultaneously
Payment confirmation	FCM push + SMS	No fallback — both sent simultaneously


12. Send — Package Delivery Flow
Send is a distinct request type within the same platform. A rider is dispatched to collect a package from a sender and deliver it to a recipient. No passenger is on the vehicle. The flow differs from a standard ride in several important ways.

12.1 How Send Differs From a Ride
Aspect	Ride	Send
Passenger	Present on vehicle	None — package only
Pricing	Distance-based, passenger pays	Distance-based, sender or recipient pays
Payment timing	After ride	Before or after — sender's choice at booking
Who pays	Passenger	Sender or recipient — configured at booking
Proof of completion	Driver marks complete	Driver photographs delivered package + recipient confirms in-app
Cancellation	Either party	Sender only — cannot cancel after driver picks up package
Liability	Platform not liable	Platform not liable — stated clearly at booking
Ratings	Passenger rates driver	Sender rates driver — recipient not in the system

12.2 Send Booking Flow
•	Sender opens app, selects Send category
•	Enters pickup location (where package is) and delivery location
•	Describes item — free text field, checked against prohibited_items table
•	If item description matches a prohibited keyword — booking blocked with explanation
•	Selects item size: Small (fits in a backpack), Medium (box up to 10kg), Large (up to 30kg)
•	Enters recipient name and phone number
•	Selects who pays: Sender pays now, Sender pays on delivery, Recipient pays on delivery
•	Fare quoted upfront based on distance — same dynamic pricing engine as rides
•	Sender confirms booking — dispatched to nearest available Send-category driver

12.3 Driver Flow for Send
•	Driver receives request — sees pickup location, item size, and delivery location
•	Driver accepts — navigates to sender's location
•	At pickup: driver and sender confirm item matches description — driver can reject if item seems prohibited or misrepresented
•	Driver photographs package before departure — stored as proof of collection
•	Driver navigates to recipient
•	At delivery: recipient confirms receipt in-app via SMS link — no app required for recipient
•	Driver photographs delivered package at recipient door — proof of delivery
•	Ride transitions to COMPLETED — payment triggered based on sender's chosen payment config

12.4 Recipient Confirmation Without an App
Recipients are not required to have the app installed. This is critical — requiring recipient installation kills the feature. Instead:
•	When driver arrives at destination, system sends recipient an SMS with a one-time confirmation link
•	Recipient taps link — opens a lightweight mobile web page, confirms delivery with one tap
•	Confirmation is timestamped and stored against the delivery record
•	If recipient is unresponsive for 10 minutes — driver can mark delivered with photo evidence alone

12.5 Prohibited Items
•	Checked at booking against the prohibited_items table — keyword match against item description
•	Severity levels: warn (show warning but allow) or block (prevent booking entirely)
•	Blocked items include: cash, firearms, alcohol, pharmaceutical drugs, illegal items, live animals
•	Warned items include: fragile electronics, food items, high-value jewellery — sender acknowledges no platform liability
•	Prohibited items list is managed from admin dashboard — no app update required to add new keywords

12.6 Liability & Disputes for Send
•	Platform is not liable for lost, damaged, or stolen packages — stated explicitly at booking confirmation
•	Proof of collection photo and proof of delivery photo are the authoritative evidence in any dispute
•	If sender claims non-delivery but driver has delivery photo and recipient confirmation — dispute resolved in driver's favor
•	If driver has no delivery photo and no recipient confirmation — dispute resolved in sender's favor
•	Platform ops team mediates but does not compensate — disputes are between sender and driver
•	Future Phase 2: optional package insurance purchasable at booking — small flat fee covers up to KES 5,000 item value


13. Women Only Category
Women Only is a Phase 2 category where both the driver and passenger must be female-verified. This addresses a real and documented safety concern for female passengers using boda bodas and ride-hailing in Kenya. The implementation requires gender verification at the account level — not just a preference toggle.

13.1 Gender Verification
•	Gender is collected at driver registration — stored in the users table
•	For drivers: gender is verified against National ID during the KYC process — ID gender must match declared gender
•	For passengers using Google Sign-In: gender is optionally provided at profile setup — not verified against an ID document
•	For passengers using phone OTP: gender declared at registration — self-declared, not verified
•	Women Only category is only visible in the passenger app to users who have declared female gender
•	Only female-verified drivers appear in the Women Only driver pool

13.2 Technical Enforcement
•	Driver table has gender_verified boolean — set to true only after KYC confirms gender matches ID
•	Passenger app hides Women Only category entirely if user gender is not set to female
•	Dispatch engine has a dedicated Redis key set: women_only:drivers:{cell_id} — contains only female-verified available driver IDs
•	When a Women Only request comes in, dispatch queries only this key set — not the general supply pool
•	A non-female driver cannot appear in Women Only requests regardless of proximity or availability

13.3 Handling Edge Cases
Scenario	Handling
Female driver goes online but hasn't completed gender verification	Not added to women_only Redis key — only verified drivers appear
Passenger changes gender in profile after booking Women Only ride	Gender change requires ops review — not instant to prevent abuse
No female drivers available in zone	Passenger notified with honest wait time — cannot be matched to male driver
Driver misrepresents gender during KYC	Flagged during verification — KYC provider cross-checks ID gender field
Passenger reports male driver arrived for Women Only ride	Immediate account suspension for driver, full refund for passenger, priority ops investigation


14. Category-Aware Dispatch Engine
The dispatch engine must now filter by vehicle category before proximity ranking. A passenger requesting a Basic car cannot be matched to a motorbike driver, regardless of proximity.

14.1 Updated Matching Flow
•	Ride request arrives with vehicle_category_slug (e.g. 'basic', 'motorbike', 'send')
•	Dispatch engine queries Redis: zone:{cell_id}:supply:{category_slug} for the passenger's zone and adjacent zones
•	For Women Only requests: queries women_only:drivers:{cell_id} instead of general supply key
•	Candidate driver pool is now category-filtered before any proximity or ETA calculation
•	From the filtered pool, drivers are ranked by road ETA via Google Directions API
•	Offer sent to lowest ETA driver — 15-second accept window, then next driver

14.2 Supply Key Structure
Each zone now tracks supply independently per category. This means surge pricing is also category-specific — a shortage of Basic cars in Westlands does not affect motorbike surge in the same zone.
zone:{cell_id}:supply:motorbike       → integer
zone:{cell_id}:supply:electric_motorbike → integer
zone:{cell_id}:supply:basic           → integer
zone:{cell_id}:supply:send            → integer
zone:{cell_id}:demand:motorbike       → integer
zone:{cell_id}:demand:basic           → integer
... and so on per category

14.3 Driver Going Online
•	Driver taps 'Go Online' in app
•	Backend checks subscription is active for their vehicle_category_id — blocks if expired
•	Driver added to Redis: driver:{id}:status → AVAILABLE
•	Driver's category slug written to driver:{id}:location alongside GPS coordinates
•	zone:{cell_id}:supply:{category_slug} incremented atomically
•	If female-verified driver: also added to women_only:drivers:{cell_id} set

14.4 Driver Going Offline
•	zone:{cell_id}:supply:{category_slug} decremented atomically
•	driver:{id}:status set to OFFLINE
•	If female driver: removed from women_only:drivers:{cell_id}
•	All cleanup operations are atomic using Redis pipelines — partial state is not possible


15. Scalability Plan
Phase 1 — Nairobi Launch (0–5,000 drivers)
Start as an Elixir Umbrella monolith — all child apps in one deployable release, sharing the same BEAM instance. Single PostgreSQL instance, single Redis instance, single GCP region. Oban handles all background jobs backed by PostgreSQL — no separate job queue infrastructure needed.
•	Infrastructure: 1 app server (GCP e2-standard-4), 1 PostgreSQL, 1 Redis
•	Expected load: ~1,250 Redis writes/second at 5,000 active drivers
•	Do not over-engineer — ship fast, learn from real usage

Phase 2 — Multi-City (5,000–50,000 drivers)
•	Elixir's BEAM clustering — connect multiple nodes into a single distributed system using libcluster. Phoenix Presence works across nodes automatically — no Redis pub/sub needed for presence at this stage.
•	Extract boda_location into its own BEAM node first — it handles the highest write volume
•	PostgreSQL read replicas for analytics and reporting queries
•	Redis Sentinel for high availability — automatic failover
•	GCP Load Balancer across multiple Elixir nodes
•	Dedicated DevOps engineer needed at this stage

Phase 3 — National Scale (50,000+ drivers)
•	Extract child apps into independent BEAM releases as load demands — transport layer change only, business logic unchanged
•	Redis Cluster — sharded by S2 cell ID for regional isolation
•	Multi-region GCP deployment — Nairobi, Mombasa, Kisumu regions
•	Kafka or Broadway (Elixir-native) for high-throughput async event processing
•	ML-based demand prediction for proactive surge pricing — Python ML service called from Elixir via HTTP
•	Elixir's BEAM can handle 50,000 active drivers on 2–3 nodes before this phase even becomes necessary


16. Resilience & Failure Handling
Failure Scenario	Detection	Response
Driver goes offline mid-ride	No location ping for 60 seconds	Alert passenger, flag ride for ops review, trigger refund logic
Redis goes down	Health check failure	Redis Sentinel auto-failover to replica within seconds
PostgreSQL goes down	Connection pool timeout	Read-only mode from replica, queue writes for retry
M-Pesa timeout	No webhook within 30 seconds	Poll Daraja transaction status API, never assume failure
Dispatch Engine overload	Queue depth exceeds threshold	Auto-scale Dispatch instances on GCP, shed non-critical load
Data center failure (GCP region down)	GCP health alerts	Failover to secondary region — driver app holds trip state locally (like Uber's approach)


17. Security
•	All API communication over HTTPS/TLS 1.3
•	JWT tokens with 24-hour expiry, refresh tokens for seamless re-auth
•	M-Pesa webhook signature validation — reject unsigned callbacks
•	Driver document verification before account activation (ID, license, plate)
•	Phone number as primary identifier — OTP via SMS, no passwords
•	Rate limiting on OTP requests — prevents SMS bombing attacks
•	Passenger trip sharing — live link shareable via WhatsApp, no account needed
•	Driver phone used as backup trip data store — encrypted state digest per Uber's DR approach


18. Driver Verification & KYC System
Every boda rider must be verified before they can go online and receive rides. This is not optional — it protects passengers, builds platform trust, and is a legal requirement in Kenya. The verification system combines automated AI checks with a human review fallback, targeting a decision within 24 hours of submission.

15.1 Documents Required

Document	Purpose	Mandatory
National ID (front & back)	Confirms identity — name, ID number, date of birth	Yes
Driver's Licence	Confirms legal right to ride — class, expiry date	Yes
PSV Badge (Public Service Vehicle)	Required by NTSA for commercial boda boda operation in Kenya	Yes
Good Conduct Certificate	Criminal background check issued by Kenya Police	Yes
Motorbike Logbook	Confirms vehicle ownership and registration	Yes
Insurance Certificate	Confirms the bike is insured for commercial use	Yes
Selfie / Liveness Photo	Matches face to ID photo — confirms person is real, not a photo of a photo	Yes

15.2 Verification Flow
•	Driver downloads app and registers with phone number + OTP
•	Prompted to complete verification before they can subscribe or go online
•	Document upload screen guides driver through each required document — one at a time
•	Each document is photographed in-app using guided capture (auto-crop, glare detection, blur detection)
•	Documents submitted to AI verification pipeline immediately on upload
•	Selfie with liveness check taken last — prevents use of printed photos or screens
•	Verification status shown in real time: Pending → Under Review → Approved / Rejected
•	Rejected documents show specific reason and allow resubmission

15.3 AI Verification Pipeline
Each document passes through multiple automated checks before reaching a human reviewer. This reduces manual workload by handling obvious fakes automatically.

Stage 1 — Document Authenticity Checks
•	OCR (Optical Character Recognition) — extracts text from ID, licence, logbook
•	MRZ (Machine Readable Zone) validation — Kenya National IDs contain MRZ codes that are cryptographically verifiable
•	Font and layout analysis — Kenyan government documents have specific fonts, spacing, and print patterns; deviations are flagged
•	Watermark and security feature detection — holograms, stamps, microprint
•	QR code verification — newer Kenya IDs contain QR codes linkable to IPRS (Integrated Population Registration System)
•	Expiry date extraction and validation — expired licence or insurance = automatic rejection

Stage 2 — AI-Generated / Deepfake Document Detection
•	Texture analysis — AI-generated ID images have subtle pixel-level artifacts that differ from genuine printed-and-photographed documents
•	Metadata analysis — image EXIF data can reveal if a photo was taken by a camera or generated/edited digitally
•	Screen recapture detection — checks for moiré patterns that appear when photographing a screen
•	Edge and shadow analysis — real physical documents cast shadows and have physical edges; printed flat images do not
•	Model confidence score — each check returns a 0–1 confidence score; scores below threshold trigger human review

Stage 3 — Face Matching
•	Selfie taken in-app is compared to the photo on the National ID using facial recognition
•	Similarity score generated — above 0.85 is auto-approved, below 0.70 is auto-rejected, 0.70–0.85 goes to human review
•	Liveness detection — driver asked to blink, turn head, or smile to confirm they are physically present
•	Deepfake video detection — flags injected video streams or face-swap attacks

Stage 4 — Cross-Document Consistency Check
•	Name on National ID must match name on Driver's Licence — mismatch flagged
•	ID number cross-referenced across all submitted documents
•	Date of birth consistency checked across documents
•	Motorbike plate on logbook cross-checked against plate on insurance certificate

Stage 5 — External Database Checks (Phase 2)
•	NTSA API — verify driver's licence status and PSV badge validity against National Transport and Safety Authority database
•	IPRS API — verify National ID against Kenya's Integrated Population Registration System
•	Kenya Police Good Conduct — manual check at launch, API integration in Phase 2

15.4 Human Review Queue
Cases that AI cannot confidently resolve are escalated to a human reviewer on the admin dashboard.
•	Reviewer sees all uploaded documents side by side with AI confidence scores and flagged issues
•	Reviewer can approve, reject (with reason), or request resubmission of specific documents
•	Target: human review completed within 2 hours during business hours
•	Driver notified via push notification and SMS when decision is made
•	All review decisions logged with reviewer ID and timestamp for audit trail

15.5 Vehicle Verification
•	Motorbike plate number entered by driver during registration
•	Logbook photo submitted — plate, engine number, and chassis number extracted via OCR
•	Insurance certificate verified for commercial use coverage — private insurance is insufficient for boda boda operation
•	Vehicle photo required — front, back, and side — to confirm physical existence of the bike
•	Plate must match across logbook, insurance, and vehicle photos — any mismatch triggers rejection
•	Phase 2: NTSA integration to verify vehicle registration status in real time

15.6 Continuous Verification (Post-Approval)
Verification does not end at onboarding. Ongoing checks maintain platform integrity.
•	Annual re-verification — driver prompted to resubmit documents when licence or insurance approaches expiry
•	Spot checks — random in-app selfie requests during active shifts to confirm driver matches registered profile (same approach Uber uses)
•	Rating-triggered review — drivers dropping below 3.5 stars are flagged for manual account review
•	Passenger reports — multiple reports of wrong driver, unsafe behavior, or fake bike trigger immediate account suspension pending investigation
•	Subscription payment device tracking — if subscription is paid from a different device than usual, flag for review

15.7 Fraud Patterns to Monitor

Fraud Type	Detection Method	Response
AI-generated fake ID	Texture analysis, metadata, edge detection	Auto-reject, flag account, block phone number
Same person, multiple accounts	Face matching across all registered drivers	Merge or ban duplicate accounts
Borrowed licence (riding under another's credentials)	Spot-check selfie vs registered face	Suspend account, escalate to ops team
Unregistered / stolen bike	Plate cross-check with logbook and insurance	Auto-reject vehicle, request resubmission
Expired documents active	Scheduled nightly job checks all expiry dates	Suspend driver, send renewal reminder
GPS spoofing (fake location)	Detect mock location apps on device, movement pattern analysis	Flag ride, suspend driver if confirmed
Account sharing (multiple drivers, one account)	Liveness spot checks, device fingerprinting	Suspend account, investigate

15.8 Build vs Buy Decision
Building a full document verification AI from scratch is expensive and slow. The recommended approach for launch is to integrate a third-party KYC API and build the workflow layer on top.

Option	Recommended For	Notes
Sumsub	Phase 1 launch	Supports Kenya IDs, driver licence validation, liveness detection, deepfake detection. Pay-per-verification model suits early stage.
iDenfy	Phase 1 alternative	Strong document coverage, human-in-the-loop review built in, fast onboarding SDK.
Build in-house	Phase 3	Only makes sense at high volume (100k+ verifications/month) where cost per verification justifies the engineering investment.
At launch, integrate Sumsub or iDenfy via their SDK — this handles document capture, AI checks, liveness, and human review. Your admin dashboard receives webhooks with verification results and the ops team handles edge cases only.


19. MVP — What To Build First
Do not build everything. The MVP must be live in under 3 months. Ship the following and nothing else:

Feature	Priority	Notes
Driver onboarding + document upload	P0	Gate to everything else
KYC verification via Sumsub/iDenfy SDK	P0	No verification, no safe platform
M-Pesa subscription payment	P0	No payment, no revenue
Passenger booking flow	P0	Core product
Driver-passenger matching	P0	Core product
Real-time driver tracking	P0	Core UX
Basic dynamic pricing	P0	Simplified — ratio-based, no ML
FCM push notifications	P0	Ride requests won't work without this
Human review queue in admin dashboard	P0	Ops team must approve drivers before they go live
Ride ratings	P1	Important but not blocking launch
SMS fallback notifications	P1	Important for Kenya — not day-one
Driver earnings dashboard	P1	Drivers want this early
Spot-check selfie verification	P1	Post-launch ongoing trust feature
NTSA API integration	P2	Phase 2 — verify licence and PSV badge in real time
IPRS API integration	P2	Phase 2 — verify National ID against government database
In-house document AI	P3	Phase 3 only — high volume justifies the build
Advanced surge (weather, events)	P2	Phase 2 feature
Scheduled rides	P2	Phase 2 feature


20. Ride State Machine
Every ride must follow a strictly defined set of states and legal transitions. Without a formal state machine, bugs like double-charging, payments firing twice, or rides stuck in limbo are inevitable. Each transition is written atomically to PostgreSQL — state update and outbox event in the same database transaction.

17.1 Ride States
State	Meaning	Who Triggers It
SEARCHING	Passenger has confirmed booking, system is finding a driver	System (auto on booking confirmed)
MATCHED	Driver has been assigned, has not yet accepted	Dispatch Engine
ACCEPTED	Driver accepted the ride, heading to pickup	Driver app
DRIVER_ARRIVED	Driver has reached the pickup point	Driver app
IN_PROGRESS	Passenger is on the bike, ride started	Driver app
COMPLETED	Driver marked ride as finished at destination	Driver app
CANCELLED_BY_PASSENGER	Passenger cancelled before ride started	Passenger app
CANCELLED_BY_DRIVER	Driver cancelled after accepting	Driver app
NO_SHOW_PASSENGER	Driver arrived, waited, passenger never came	System (auto after timeout)
NO_SHOW_DRIVER	Driver never arrived after accepting	System (auto after timeout)
FAILED	System could not find any driver after all retries	Dispatch Engine

17.2 Legal State Transitions
SEARCHING → MATCHED (driver found)
SEARCHING → FAILED (no drivers available after retries)
MATCHED → ACCEPTED (driver accepts)
MATCHED → SEARCHING (driver declines or timeout — retry next driver)
ACCEPTED → DRIVER_ARRIVED (driver marks arrived)
ACCEPTED → CANCELLED_BY_DRIVER (driver cancels)
ACCEPTED → CANCELLED_BY_PASSENGER (passenger cancels — fee may apply)
DRIVER_ARRIVED → IN_PROGRESS (driver starts ride)
DRIVER_ARRIVED → NO_SHOW_PASSENGER (passenger timeout — 5 minutes)
DRIVER_ARRIVED → CANCELLED_BY_PASSENGER (passenger cancels on arrival)
IN_PROGRESS → COMPLETED (driver marks complete)
Any transition not listed above is illegal and must be rejected with an error. For example: jumping from SEARCHING directly to IN_PROGRESS is impossible and should never be allowed regardless of client input.

17.3 Outbox Pattern for Reliable Events
Every state transition triggers side effects — notifications, payments, analytics events. These must never be lost even if the system crashes mid-operation. The outbox pattern solves this:
•	State update and outbox event are written in a single PostgreSQL transaction — either both succeed or both fail
•	A background worker reads the outbox table and publishes events to downstream services
•	If the worker crashes, it retries from the last unprocessed outbox entry — no event is lost
•	Events are idempotent — processing the same event twice produces the same result


21. Cancellation & No-Show Policy
Cancellations are free on Liddr — for both passengers and drivers. As an early-stage platform, charging cancellation fees creates friction, erodes trust, and discourages adoption. The focus at launch is growth and goodwill. Abuse is managed through behavioural limits and account actions, not fees.

18.1 Passenger Cancellation
•	Passengers can cancel at any time before IN_PROGRESS state — no charge
•	Cancellation reason is optionally collected from passenger for analytics — helps identify systemic issues like drivers not moving
•	A cancellation counts against the passenger only if it is chargeable. It is not chargeable when no driver has been assigned, within 2 minutes of a driver accepting, for a safety concern or emergency, or when the evidence shows the driver was late, had stopped sending a location, was not making progress, or was too far away
•	5 chargeable cancellations or no-shows in 7 days pause the passenger's bookings for 24 hours — abuse prevention without money
•	8 chargeable cancellations or no-shows in 7 days pause the passenger's bookings for 7 days
•	Cancellation data is tracked per passenger and surfaces in ops dashboard for pattern review

18.2 Driver Cancellation
•	Driver can cancel only before IN_PROGRESS state — cannot cancel once ride has started
•	Driver cancellations after ACCEPTED state are logged and monitored
•	More than 3 driver cancellations per day triggers an in-app warning notification
•	More than 10 driver cancellations in a week triggers account review — high cancellation rates hurt passenger experience and driver reliability scores
•	Reliability score is visible to passengers on the driver's profile — social accountability replaces financial penalty

18.3 Passenger No-Show
•	After DRIVER_ARRIVED state, driver waits a maximum of 5 minutes
•	System sends passenger a push notification and SMS warning at the 2-minute mark
•	If passenger does not respond or arrive within 5 minutes, ride transitions to NO_SHOW_PASSENGER automatically
•	No financial penalty at launch — driver is freed immediately to accept a new ride
•	Each no-show counts toward the booking pause limits in 18.1
•	Future consideration: once platform has scale and trust, introduce a nominal no-show fee as driver compensation

18.4 Driver No-Show / Ghost Driver
•	If driver location does not move toward pickup for 3 minutes after ACCEPTED state, system alerts passenger
•	If driver does not reach pickup within a reasonable ETA window, ride is escalated to ops review
•	Passenger is offered a free rematch immediately — no friction, no penalty
•	Driver account flagged — ghost driving is a serious trust violation
•	Confirmed ghost driving triggers immediate account suspension pending ops review


22. Dispute Resolution System
Disputes are inevitable. Without a structured resolution system, response times balloon and driver/passenger churn follows. Every dispute must be traceable, time-bound, and fair.

19.1 Dispute Categories
Category	Examples	Auto-Resolvable?
Fare dispute	Charged more than quoted fare, surge not disclosed	Yes — compare quoted vs charged fare in database
Driver did not arrive	Driver marked arrived but GPS shows different location	Yes — compare driver GPS to pickup coordinates
Wrong route taken	Driver took longer route, inflating fare	Yes — compare actual GPS trace to Google Maps optimal route
Safety incident	Driver was reckless, harassed passenger	No — requires human review
Lost item	Passenger left item on bike	No — requires human mediation
Payment not received	Driver says passenger did not pay	Partial — M-Pesa logs are authoritative
Wrong driver	Different person showed up vs app profile	No — requires immediate escalation + safety protocol
App error	Ride charged but trip never happened	Yes — cross-reference ride state machine logs

19.2 Dispute Flow
•	Passenger or driver submits dispute via in-app form within 48 hours of ride completion
•	System auto-classifies dispute category based on submission text and ride data
•	Auto-resolvable disputes are decided immediately using ride logs — decision communicated within 5 minutes
•	Non-auto-resolvable disputes enter the human review queue with all relevant data attached: GPS trace, M-Pesa records, ride timeline, driver and passenger history
•	Target resolution time for human review: 24 hours
•	Both parties notified of outcome via push notification and SMS
•	Either party can escalate once — escalated disputes go to senior ops reviewer

19.3 Refund Logic
•	Refunds issued via M-Pesa reversal or wallet credit — passenger chooses
•	Refund decisions logged with reviewer ID, timestamp, and reason for audit trail
•	Fraudulent dispute patterns (serial disputers) are tracked and flagged — accounts with more than 5 successful disputes in 30 days are reviewed


23. Data Privacy & Regulatory Compliance
Kenya enacted the Data Protection Act in 2019. Operating a platform that collects biometric data (face scans), government ID data, and real-time location data makes compliance non-optional. Non-compliance can result in fines and platform shutdown.

20.1 Kenya Data Protection Act 2019
•	Appoint a Data Protection Officer (DPO) before launch — legally required for platforms processing sensitive personal data
•	Register with the Office of the Data Protection Commissioner (ODPC)
•	Users must give explicit informed consent before any data collection — consent captured in-app at registration
•	Users have the right to access, correct, and delete their data — provide in-app data management tools
•	Data breach notification — if a breach occurs, ODPC must be notified within 72 hours
•	Location data is sensitive — only collected while app is in active use, not in the background when no ride is active
•	Biometric data (selfies, face scans) must be stored in private storage and deleted when no longer needed. A driver's approved selfie is also their photo on the rider's trip screen, with the driver's explicit consent recorded when they apply, and riders only ever receive a link that expires after 5 minutes

20.2 NTSA Regulatory Compliance
•	Boda boda commercial operations require PSV licensing under NTSA regulations
•	Platform must maintain records of all driver verifications available for NTSA audit on request
•	Incident reporting — any serious accident involving a platform driver must be reported to NTSA
•	Phase 2: formal partnership with NTSA for real-time licence and PSV badge verification via API

20.3 Kenya Revenue Authority (KRA)
•	Digital marketplace platforms are required to report transaction data to KRA under the Finance Act 2023
•	Ensure subscription payments and any ride commission revenue is properly declared
•	Driver earnings reported through the platform may require tax withholding mechanisms in Phase 2

20.4 Data Minimization & Retention
Data Type	Retention Period	Deletion Policy
Real-time driver location (Redis)	30 seconds TTL	Auto-expired by Redis TTL
Historical GPS traces	12 months	Auto-deleted after 12 months — needed for disputes
Ride records	5 years	Legal requirement for financial records
Payment records	7 years	KRA compliance requirement
Verification documents (ID, licence)	Duration of account + 1 year	Deleted 1 year after account closure
Driver selfie in use as driver's photo	While the account is open	Deleted 30 days after account closure
Other selfies (replaced, rejected, or from a rejected application)	30 days	Deleted 30 days after the decision
Dispute records	3 years	Needed for audit trail and escalation history


24. Observability & Monitoring
You cannot manage what you cannot measure. Observability must be built in from day one — not added later when something breaks in production at 7am.

21.1 The Three Pillars
Logs
•	Structured JSON logs from every service — include ride_id, driver_id, passenger_id, and timestamp on every log line
•	Log every state transition with before/after state, triggering event, and actor
•	Log every payment attempt, result, and M-Pesa reference number
•	GCP Cloud Logging for centralized log aggregation

Metrics
•	Ride funnel: requests → matched → accepted → completed — track drop-off at each step
•	Matching latency: time from ride request to driver acceptance
•	Driver utilization rate: percentage of online drivers actively on a ride
•	Subscription renewal rate: how many drivers renew each week vs lapse
•	M-Pesa success rate: percentage of STK push payments that complete
•	GCP Cloud Monitoring with custom dashboards per service

Alerts
•	Matching failure rate > 10% for any zone — immediate alert to ops
•	M-Pesa success rate drops below 95% — payment system issue
•	Redis memory usage > 80% — scale warning
•	WebSocket connection drop rate spike — connectivity issue
•	Driver app GPS ping gap > 10 seconds for active rides — tracking failure
•	Subscription renewal rate drops more than 20% week-over-week — churn alert

21.2 Error Tracking
•	Sentry for crash reporting on both mobile apps (Android Kotlin, iOS Swift) and Elixir backend — Sentry has a first-class Elixir SDK.
•	Every unhandled exception captured with full context — user ID, device, app version, ride state at time of crash
•	P0 crashes (affecting ride in progress) trigger immediate PagerDuty alert to on-call engineer

21.3 App Version Management
•	All API responses include minimum_required_version header
•	If client app version is below minimum, API returns 426 Upgrade Required with deep link to app store
•	Forced upgrades reserved for critical security patches or breaking API changes only
•	Gradual rollouts — new app versions released to 5% of users first, monitored for crash rate, then expanded
•	Backend must maintain backward compatibility for at least 2 prior app versions at all times


25. Rate Limiting & Abuse Prevention
Without rate limiting, a single misbehaving client can degrade service for all users. This is implemented at the API Gateway level using Redis counters.

Endpoint	Rate Limit	Action on Exceed
OTP request	3 per phone number per hour	Block for 1 hour, alert ops if repeated
Ride request	10 per passenger per hour	429 Too Many Requests response
Driver location ping	1 per 3 seconds per driver	Silently drop excess pings — do not error
Dispute submission	3 per ride, 10 per user per week	Block with message to contact support
Document upload (KYC)	5 attempts per document type per day	Block with resubmission cooldown
Admin login	5 attempts per IP per 15 minutes	IP block + alert security team

22.1 Passenger Abuse Patterns
•	Requesting rides and immediately cancelling repeatedly — tracked and flagged within 1 hour window
•	Creating multiple accounts from same device — device fingerprinting detects and links accounts
•	Using same M-Pesa number across multiple accounts — flagged for review

22.2 Driver Abuse Patterns
•	GPS spoofing — driver app detects mock location APIs on device and flags to backend
•	Trip inflation — GPS trace analysis detects routes significantly longer than optimal — auto-flagged
•	Account sharing — liveness spot checks verify active driver matches registered profile


26. Ratings System
Ratings are the trust layer of the platform. They determine which drivers get priority in dispatch, signal quality to passengers before they book, and protect both sides from bad actors. A poorly designed rating system is easy to game and quickly becomes meaningless. This section covers the full design — calculation, display, enforcement, and manipulation prevention.

26.1 Who Rates Who
After a...	Who Rates	Who Is Rated	Visible To
Ride	Passenger rates driver	Driver	All passengers on driver's profile
Ride	Driver rates passenger	Passenger	Drivers only — before accepting a ride request
Send delivery	Sender rates courier	Driver/courier	All users on driver's profile
Send delivery	Driver rates sender	Sender	Drivers only
Passengers do not see their own rating directly — but drivers see it before accepting a request. A passenger with a consistently low rating (rude behavior, no-shows, false disputes) may find drivers declining their requests more often. This is intentional — it mirrors how Uber and Bolt handle this and creates accountability on both sides without being confrontational.

26.2 Rating Scale & Prompt
•	1 to 5 stars — industry standard, universally understood
•	Rating prompt appears immediately after ride completion — while experience is fresh
•	Prompt times out after 24 hours — after that, ride can no longer be rated
•	Comment is optional — free text, max 200 characters
•	Driver rating prompt shown to passenger first — driver rates passenger second, after their own rating is submitted, to prevent retaliation bias
•	Skipping is allowed — a skipped rating is not counted, not treated as a 1-star

26.3 Score Calculation — Weighted Rolling Average
A simple average is a poor signal for driver quality. A driver with 500 rides and a consistently good recent record should not be dragged down by 3 bad ratings from their first week. Equally, a driver who was great 2 years ago but has declined recently should not coast on old scores.
Liddr uses a weighted rolling average where recent ratings carry more weight than older ones:
weight = 1 / (1 + days_since_rating * decay_factor)
weighted_score = sum(rating * weight) / sum(weight)
Decay factor is set to 0.01 — meaning a rating from 100 days ago carries roughly half the weight of a rating from today. This is recalculated on every new rating submission, not in batch.

26.4 Minimum Rides Threshold
•	A driver's public rating is not displayed until they have completed at least 10 rated rides
•	Before 10 rated rides, profile shows 'New Driver' badge instead of a score
•	This prevents a single bad rating from destroying a new driver's profile before they have a fair chance
•	Dispatch engine treats new drivers as neutral (equivalent to 4.5) for priority purposes until threshold is met

26.5 How Ratings Affect Dispatch Priority
When multiple drivers are equidistant from a passenger, rating is the tiebreaker. The dispatch engine uses a composite score:
dispatch_score = (0.7 * eta_score) + (0.3 * rating_score)
ETA still carries the majority weight — a 4.9-rated driver who is 10 minutes away loses to a 4.2-rated driver who is 2 minutes away. But between drivers with similar ETAs, the higher-rated driver wins the offer first.
•	eta_score is normalized: 1.0 for lowest ETA in candidate pool, scales down proportionally
•	rating_score is normalized: 1.0 for 5.0 stars, 0.0 for 1.0 star
•	New drivers (below threshold) use a neutral rating_score of 0.7

26.6 Rating Thresholds & Enforcement
Driver Rating	Action	Timeline
Below 4.0	In-app warning sent — tips for improvement shown	Immediate
Below 3.7 sustained over 30 rides	Account review triggered — ops team notified	Auto-flagged
Below 3.5 sustained over 50 rides	Account suspended pending improvement plan	After ops review
Below 3.0 at any point with 20+ rides	Account suspended immediately	Immediate
Passenger below 3.5 (driver ratings)	Drivers can see low passenger score — may decline	Ongoing
Passenger below 3.0 sustained	Account review — possible suspension	After ops review
•	Suspended drivers can appeal — ops reviews last 20 ride rating breakdown before deciding
•	Drivers on improvement plan are monitored for 4 weeks — suspension lifted if score recovers above 4.0

26.7 Rating Display on Driver Profile
The passenger sees the following on the driver's profile card during the booking confirmation screen:
•	Driver photo — their approved verification selfie, while the trip is under way
•	Star rating (1 decimal place — e.g. 4.7) — shown only if above minimum threshold
•	Total number of completed rides — builds confidence in experienced drivers
•	New Driver badge — if below threshold
•	Helmet Confirmed badge — if driver has a clean helmet confirmation record
•	Top Rated badge — automatically awarded to drivers sustaining 4.8+ over 100+ rides
•	Category icon — motorbike, car, etc.
•	Last 3 written comments — most recent first, anonymised

26.8 Rating Manipulation Prevention
Fake ratings are a serious platform integrity issue. The following controls are in place:
•	A rating can only be submitted by a user who was an active participant in that specific ride — ride_id is validated against passenger_id and driver_id in the ratings table
•	One rating per ride per direction — database unique constraint on (ride_id, rated_by)
•	Device fingerprinting — multiple accounts submitting ratings from the same device are flagged
•	Velocity check — a driver receiving more than 10 five-star ratings in one hour is auto-flagged for review
•	New account ratings are weighted lower for the first 30 days — reduces impact of fake account farms
•	Coordinated rating patterns — if the same passenger rates the same driver five stars across many consecutive rides with no other rating activity, flagged as suspicious
•	Ops team can nullify specific ratings with reason logged — all nullifications are auditable

26.9 Send-Specific Rating Considerations
•	Sender rates courier after delivery confirmation — not before
•	Rating prompt only unlocks after proof of delivery photo is submitted and recipient has confirmed or timeout has passed
•	Rating criteria for Send differs slightly — stars reflect punctuality, item handling care, and communication rather than driving comfort
•	Optional tag system for Send ratings: On Time, Handled Carefully, Good Communication, Damaged Item, Late Delivery — tags feed into analytics without requiring written comments

26.10 Database & Redis Design for Ratings

PostgreSQL
•	ratings table: id, ride_id, rated_by, rated_user, score, comment, created_at, is_nullified, nullified_by, nullified_reason
•	users table: rating_score (float, updated on every new rating), rating_count (integer, total rated rides), rating_weighted_sum (float, used for efficient weighted recalculation)
•	Unique constraint: (ride_id, rated_by) — prevents double rating

Redis
•	driver:{id}:rating → current weighted score, cached for fast dispatch scoring — invalidated and refreshed on every new rating
•	rating:flagged:{driver_id} → set when velocity check triggers — ops review queue

Recalculation
•	On every new rating submission, a background job recalculates the weighted score for the rated user
•	Updates users.rating_score in PostgreSQL and driver:{id}:rating in Redis atomically
•	Recalculation is async — does not block the rating submission response


27. API Contract
This section is the source of truth between the backend and both mobile platforms. Every endpoint, WebSocket channel, and request/response shape is defined here. Mobile engineers build against this contract — not against assumptions or reverse-engineered behaviour. When the contract changes, this document is updated first.

27.1 Base URL & Versioning
Production:   https://api.liddr.app/api
Staging:      https://api-staging.liddr.app/api
Local:        http://localhost:4000/api
Current backend routes are mounted under /api.

27.2 Authentication
All protected endpoints require a Bearer token in the Authorization header:
Authorization: Bearer <jwt_token>
Access tokens expire after 15 minutes. Refresh tokens are rotated and expire after 30 days. Unauthenticated requests return HTTP 401.

27.3 Standard Response Shape
All API responses use a JSON envelope:
// Success
{
  "data": { ... }
}

// Error
{
  "error": {
    "code": "RIDE_NOT_FOUND",
    "message": "The requested ride does not exist"
  }
}

27.4 Auth Endpoints
Method	Endpoint	Description	Auth Required
GET	/auth/methods	List supported auth methods	No
POST	/auth/register/rider	Register rider identity	No
POST	/auth/register/driver	Register driver identity	No
POST	/auth/challenges	Request OTP/auth challenge	No
POST	/auth/challenges/verify	Verify challenge and create session	No
POST	/auth/refresh	Refresh expired JWT using refresh token	No
POST	/auth/logout	Invalidate current session	No (requires refresh token payload)

27.5 Ride Endpoints
Method	Endpoint	Description	Auth Required
POST	/rides/quote	Quote fare before booking	Yes — Rider
POST	/rides/requests	Create a new ride request	Yes — Rider
POST	/rides/:ride_id/cancel	Rider cancel before trip start	Yes — Rider
GET	/rides/history/rider	Rider ride history	Yes — Rider
GET	/rides/history/driver	Driver ride history	Yes — Driver
GET	/rides/:ride_id	Get ride details	Yes — Rider/Driver
POST	/rides/:ride_id/rate	Submit rating after completion	Yes — Rider/Driver
POST	/rides/:ride_id/rate/skip	Skip rating action	Yes — Rider/Driver

27.6 Driver Endpoints
Method	Endpoint	Description	Auth Required
POST	/drivers/me/online	Go online — start receiving requests	Yes — Driver
POST	/drivers/me/offline	Go offline	Yes — Driver
POST	/drivers/me/location	Upsert latest driver GPS point	Yes — Driver
GET	/rides/offers	List active ride offers	Yes — Driver
POST	/rides/offers/:offer_id/accept	Accept ride offer	Yes — Driver
POST	/rides/offers/:offer_id/reject	Reject ride offer	Yes — Driver

27.7 Subscription Endpoints
Method	Endpoint	Description	Auth Required
GET	/subscriptions/me	Current subscription status and expiry	Yes — Driver
POST	/subscriptions/pay	Initiate M-Pesa STK Push for subscription	Yes — Driver
GET	/subscriptions/me/history	Past subscription payments	Yes — Driver

27.8 Send (Delivery) Endpoints
Method	Endpoint	Description	Auth Required
POST	/send/quote	Quote a Send delivery fare	Yes — Rider
POST	/send/requests	Create a Send delivery request	Yes — Rider
GET	/send/history/sender	Sender delivery history	Yes — Rider
GET	/send/history/courier	Courier delivery history	Yes — Driver
POST	/send/rides/:ride_id/pickup-proof	Capture package pickup proof photo reference	Yes — Driver
POST	/send/rides/:ride_id/dropoff-proof	Capture dropoff proof and issue recipient confirmation link	Yes — Driver
POST	/send/recipient-confirmations/:token	Recipient confirms delivery via one-time link	No

Send request payload currently supports:
•	Core delivery contacts: sender_name, sender_phone (optional fallback to rider phone), recipient_name, recipient_phone
•	Parcel details: item_description, item_size (small|medium|large), item_value_kes, special_instructions
•	Payment controls: payer (sender|recipient), payment_timing (before|after)
•	Safety policy: prohibited-item matching (warn/block), liability_acknowledged required for warned-item submissions
•	Delivery completion policy: Send rides cannot start before pickup proof; completion requires dropoff proof plus recipient confirmation or timeout window

27.9 Verification Endpoints
Method	Endpoint	Description	Auth Required
POST	/verification/applications	Start verification application	Yes — Driver
POST	/verification/uploads/presign	Request signed upload URL	Yes — Driver
POST	/verification/documents	Upload KYC document	Yes — Driver
GET	/verification/status	Get current verification status	Yes — Driver

27.10 WebSocket Channels
WebSocket connection is established at:
ws://localhost:4000/socket/websocket?token=<jwt_token>

Channel	Who Joins	Events Sent	Events Received
ride:{ride_id}	Rider + Driver	ride lifecycle + timeline events	timeline.sync
driver:{driver_id}	Driver only	offer + assignment + lifecycle events	none (unsupported)
Driver location updates are sent via HTTP endpoint POST /drivers/me/location, not via a dedicated location socket topic.

27.11 WebSocket Message Shapes
// Client requests missing timeline events after reconnect
{
  "topic": "ride:12345",
  "event": "timeline.sync",
  "payload": {
    "since": "2025-01-01T08:00:00Z",
    "limit": 100
  }
}

// Server pushes new offer to specific driver topic
{
  "topic": "driver:42",
  "event": "ride_offer_created",
  "payload": {
    "ride": { "id": 12345, "status": "offering" },
    "offer": { "id": 991, "status": "offered", "expires_at": "2025-01-01T08:00:15Z" },
    "reason_code": "dispatch_offer_created",
    "emitted_at": "2025-01-01T08:00:00Z"
  }
}


28. Development Environment
Every engineer on the project should be running identical tool versions. Version mismatches are the single biggest source of 'works on my machine' issues. This section is the canonical reference — update it whenever a version is intentionally upgraded.

28.1 Required Tools & Versions
Tool	Version	Install
Erlang/OTP	27.x	https://www.erlang.org/downloads — or via asdf
Elixir	1.17.x	https://elixir-lang.org/install.html — or via asdf
Phoenix	1.7.x	mix archive.install hex phx_new
PostgreSQL	16.x	https://www.postgresql.org/download/
Redis	7.x	https://redis.io/download — or via Docker
Node.js	20.x LTS	Required for Phoenix asset pipeline even with --no-assets
Android Studio	Hedgehog or later	https://developer.android.com/studio
Kotlin	2.0.x	Bundled with Android Studio
Xcode	15.x or later	Mac App Store — macOS only
Swift	5.9 or later	Bundled with Xcode
Git	2.40 or later	https://git-scm.com

28.2 Recommended Version Manager — asdf
asdf is a single version manager that handles Erlang, Elixir, Node.js, and more. It reads a .tool-versions file at the project root so every engineer automatically uses the correct version.
# Install asdf (macOS/Linux)
git clone https://github.com/asdf-vm/asdf.git ~/.asdf

# Add plugins
asdf plugin add erlang
asdf plugin add elixir
asdf plugin add nodejs

# Install versions defined in .tool-versions
asdf install

The .tool-versions file at the liddr root:
erlang 27.1
elixir 1.17.3-otp-27
nodejs 20.18.0

Windows developers: asdf does not support Windows natively. Use WSL2 (Windows Subsystem for Linux) for the Elixir/Phoenix development environment. Android Studio and VS Code run natively on Windows — only the Elixir toolchain needs WSL2.

28.3 Environment Variables
Never commit secrets to git. Each platform manages its own environment config:

API — api/config/dev.secret.exs (gitignored)
import Config

config :liddr, Liddr.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "liddr_dev"

config :liddr, :mpesa,
  consumer_key: "your_daraja_consumer_key",
  consumer_secret: "your_daraja_consumer_secret",
  shortcode: "your_shortcode",
  passkey: "your_passkey"

config :liddr, :google_maps_api_key, "your_google_maps_key"
config :liddr, :fcm_server_key, "your_fcm_key"
config :liddr, :africastalking_api_key, "your_at_key"

Android — android/local.properties (gitignored)
MAPS_API_KEY=your_google_maps_key
API_BASE_URL=http://10.0.2.2:4000/api
WS_BASE_URL=ws://10.0.2.2:4000/socket/websocket

Note: 10.0.2.2 is Android emulator's alias for localhost on the host machine.

iOS — ios/Liddr/Config.xcconfig (gitignored)
MAPS_API_KEY = your_google_maps_key
API_BASE_URL = http://localhost:4000/api
WS_BASE_URL = ws://localhost:4000/socket/websocket

28.4 Running The Full Stack Locally
# Terminal 1 — Start PostgreSQL (if not running as a service)
pg_ctl start

# Terminal 2 — Start Redis (if not running as a service)
redis-server

# Terminal 3 — Start the API
cd liddr/api
mix ecto.migrate        # run any pending migrations
mix phx.server          # starts on http://localhost:4000

# Android — run from Android Studio
# iOS — run from Xcode


29. Git Workflow
One repository, three platforms, multiple engineers. Without a clear workflow, the monorepo becomes chaotic fast. This section defines how code moves from an engineer's machine to production.

29.1 Branching Strategy — GitHub Flow
Liddr uses GitHub Flow — the simplest branching strategy that works for a small, fast-moving team. There is one long-lived branch (main) and short-lived feature branches. No develop branch, no release branch complexity.

Branch	Purpose	Who Creates It
main	Always deployable. Every commit here is production-ready.	Nobody directly — merged via PR only
feature/{ticket}-{description}	New feature work	Any engineer
fix/{ticket}-{description}	Bug fixes	Any engineer
chore/{description}	Dependency updates, config, tooling	Any engineer

29.2 Branch Naming Convention
feature/LID-42-driver-location-ping
feature/LID-87-mpesa-subscription-flow
fix/LID-103-websocket-reconnect-crash
chore/update-elixir-1-17-3
LID-{number} is the ticket number from your project management tool. This links every branch to a specific piece of work.

29.3 Commit Message Convention
Liddr follows Conventional Commits — a standard that makes the git history readable and enables automated changelog generation later.
feat(api): add M-Pesa STK push for subscription payment
feat(android): implement driver location ping every 4 seconds
feat(ios): add ride request screen with fare estimate
fix(api): handle Daraja webhook duplicate payment correctly
fix(android): resolve WebSocket reconnection crash on background
chore(api): upgrade Elixir to 1.17.3
docs: update API contract with send delivery endpoints

The scope in brackets — (api), (android), (ios) — makes it immediately clear which platform a commit touches. Critical in a monorepo.

29.4 Pull Request Process
•	Every change goes through a PR — no direct commits to main, ever
•	PR title follows the same Conventional Commits format as commit messages
•	PR description must include: what changed, why it changed, how to test it
•	Minimum one approval required before merge
•	CI must pass — Elixir tests, Android build, iOS build all green before merge is allowed
•	Squash and merge — keeps main history clean, one commit per feature

29.5 CI/CD Per Platform
Each platform has its own GitHub Actions workflow that runs independently on every PR:

.github/workflows/api.yml
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with: { elixir-version: '1.17', otp-version: '27' }
      - run: cd api && mix deps.get && mix test

.github/workflows/android.yml
on: [push, pull_request]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { java-version: '17', distribution: 'temurin' }
      - run: cd android && ./gradlew build

.github/workflows/ios.yml
on: [push, pull_request]
jobs:
  build:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - run: cd ios && xcodebuild -scheme Liddr -sdk iphonesimulator build

29.6 Release Flow
•	Releases are tagged on main — git tag v1.0.0
•	API is deployed to GCP via GitHub Actions on tag push
•	Android release build is triggered on tag push — APK/AAB uploaded to Play Store internal track
•	iOS release build is triggered on tag push — IPA uploaded to TestFlight
•	Semantic versioning — MAJOR.MINOR.PATCH
•	All three platforms share the same version number per release — keeps coordination simple

29.7 Gitignore Coverage
The root .gitignore covers all three platforms in one file:
# Elixir / Phoenix
api/_build/
api/deps/
api/priv/static/assets/
api/config/dev.secret.exs
api/config/prod.secret.exs

# Android
android/.gradle/
android/build/
android/local.properties
android/*.keystore

# iOS
ios/Pods/
ios/*.xcworkspace
ios/DerivedData/
ios/Liddr/Config.xcconfig

# General
.DS_Store
*.env
.env.local


Document Information
This document covers the full system design for Liddr v1.0. It should be treated as a living document — updated as architecture decisions are made or revised during development.

Field	Value
Product	Liddr
Version	1.3
Market	Kenya (Nairobi first)
Target Launch	Phase 1 MVP
Document Status	Draft — Active Development

---

## 2026-03-05 Implementation Reality Addendum (Backend Source Of Truth)

This addendum supersedes conflicting text in the sections above for the current API implementation.
Use this as the authoritative view for backend behavior until the main body is fully rewritten.

### A) Geographic Indexing And Live Location
- Live supply indexing is implemented directly with the S2 location engine and canonical hex cell tokens in Redis (`Liddr.Location.S2`, `Liddr.Location.SupplyIndex`).
- Radius covering is produced by the official `golang/geo/s2` `RegionCoverer` helper, while Elixir stores and queries the canonical S2 tokens it returns.
- Driver location ingest is HTTP (`POST /api/drivers/me/location`), not WebSocket write ingestion.
- Passenger/driver live ride updates are delivered through Phoenix Channels for ride/driver topics.

Primary evidence:
- `api/lib/liddr/location/s2.ex`
- `api/lib/liddr/location/s2_native.ex`
- `api/native/s2cover/main.go`
- `api/lib/liddr/location/supply_index.ex`
- `api/lib/liddr_web/controllers/driver_location_controller.ex`

### B) Ride Completion And Payments
- Ride completion is supported (`POST /api/rides/:ride_id/complete`).
- Subscription payment uses in-app M-Pesa with webhook + reconciliation workflows.
- Driver subscription status is enforced for availability/acceptance gates.

Primary evidence:
- `api/lib/liddr/subscriptions/payments.ex`
- `api/lib/liddr/subscriptions/reconciliation.ex`
- `api/lib/liddr_web/controllers/subscription_controller.ex`

### C) Dispute And Compensation Workflow (Implemented)
- Riders/drivers can submit ride disputes: `POST /api/disputes`.
- Ops resolves disputes with outcomes: `POST /api/ops/disputes/:id/resolve`.
- Refund outcomes (`refund_full`, `refund_partial`, `credit_note`) create a compensation record.
- Ops can process compensation:
  - mark paid: `POST /api/ops/disputes/compensations/:id/mark-paid`
  - cancel approved compensation: `POST /api/ops/disputes/compensations/:id/cancel`
- Paid transition requires settlement metadata:
  - `processing_reference` (required for `paid`)
  - `processing_channel` (`manual_ops|mpesa_reversal|wallet_credit|bank_transfer`)
- Compensation records include audit fields (`processed_at`, `processed_by_user_id`, processing metadata).

Primary evidence:
- `api/lib/liddr/disputes/cases.ex`
- `api/lib/liddr/disputes/compensations.ex`
- `api/lib/liddr_web/controllers/dispute_controller.ex`
- `api/lib/liddr_web/controllers/dispute_ops_controller.ex`
- `api/priv/repo/migrations/20260305185202_add_dispute_compensation_processing_reference_fields.exs`

### D) API Contract Drift
The route table in the earlier API contract section is incomplete for current backend scope.
For canonical routes, use:
- `api/lib/liddr_web/router.ex`

Notable implemented surfaces include:
- shared rides + member actions
- ride messaging + moderation
- destination change requests
- dispute/compensation ops
- ratings ops and moderation ops endpoints

### E) Development Environment (Current)
- API runtime uses Docker-first local development with `.env` / `.env.example`.
- Runtime configuration is in `api/config/runtime.exs`.
- Compose is at repository root (`docker-compose.yml`) to orchestrate API + Postgres + Redis + ClamAV as one stack.

### F) CI/Workflow Reality
- Git workflow conventions are documented.
- `.github/workflows` is currently not present in this repository snapshot; treat CI workflow examples above as target-state guidance.

### G) Practical Rule For Future Edits
When design prose conflicts with implemented code, backend behavior is defined by:
1. `api/lib/liddr_web/router.ex`
2. domain modules under `api/lib/liddr/`
3. schema/migrations under `api/priv/repo/migrations/`

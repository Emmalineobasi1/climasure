;; title: Climasure Insurance Pool
;; version: 1.0.0
;; summary: Core insurance pool contract for climate risk protection
;; description: Manages insurance pool funds, farmer policies, premium collection, and claim payouts for climate-related events

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-authorized (err u101))
(define-constant err-insufficient-funds (err u102))
(define-constant err-policy-not-found (err u103))
(define-constant err-policy-expired (err u104))
(define-constant err-claim-already-paid (err u105))
(define-constant err-invalid-coverage-type (err u106))
(define-constant err-insufficient-pool-reserves (err u107))
(define-constant err-policy-already-exists (err u108))
(define-constant err-invalid-coordinates (err u109))
(define-constant err-invalid-amount (err u110))

;; Coverage type constants
(define-constant coverage-drought "drought")
(define-constant coverage-flood "flood")
(define-constant coverage-temperature "temperature")

;; Pool parameters
(define-constant min-reserve-ratio u20) ;; 20% minimum reserves
(define-constant max-coverage-per-policy u100000000000) ;; 100,000 STX max coverage
(define-constant base-premium-rate u300) ;; 3% base premium rate (300 basis points)

;; Data variables
(define-data-var pool-balance uint u0)
(define-data-var total-coverage-outstanding uint u0)
(define-data-var total-premiums-collected uint u0)
(define-data-var total-claims-paid uint u0)
(define-data-var policy-nonce uint u0)
(define-data-var oracle-contract (optional principal) none)

;; Farmer registry
(define-map farmers
  principal
  {
    name: (string-ascii 100),
    location: (string-ascii 100),
    latitude: int,
    longitude: int,
    registered-at: uint,
    active-policies: uint,
    total-premiums-paid: uint,
    total-claims-received: uint
  }
)

;; Insurance policies
(define-map policies
  uint
  {
    farmer: principal,
    coverage-type: (string-ascii 20),
    coverage-amount: uint,
    premium-paid: uint,
    start-block: uint,
    end-block: uint,
    latitude: int,
    longitude: int,
    drought-threshold: (optional uint), ;; days without rain
    flood-threshold: (optional uint), ;; mm precipitation per day
    temp-min-threshold: (optional int), ;; minimum temperature in celsius * 100
    temp-max-threshold: (optional int), ;; maximum temperature in celsius * 100
    active: bool,
    claim-paid: bool,
    payout-amount: uint
  }
)

;; Pool liquidity providers
(define-map liquidity-providers
  principal
  {
    total-deposited: uint,
    total-withdrawn: uint,
    deposit-block: uint,
    share-percentage: uint
  }
)

;; Weather events for claim processing
(define-map weather-events
  { policy-id: uint, event-block: uint }
  {
    event-type: (string-ascii 20),
    severity: uint,
    verified: bool,
    payout-triggered: bool,
    recorded-at: uint
  }
)

;; Pool statistics
(define-map pool-stats
  uint
  {
    total-farmers: uint,
    active-policies: uint,
    pool-utilization: uint,
    claims-ratio: uint
  }
)

;; Public functions

;; Register farmer in the system
(define-public (register-farmer
  (name (string-ascii 100))
  (location (string-ascii 100))
  (latitude int)
  (longitude int)
)
  (let
    (
      (caller tx-sender)
    )
    (asserts! (and (>= latitude -9000000) (<= latitude 9000000)) err-invalid-coordinates)
    (asserts! (and (>= longitude -18000000) (<= longitude 18000000)) err-invalid-coordinates)
    (asserts! (> (len name) u0) err-invalid-amount)
    
    (map-set farmers caller
      {
        name: name,
        location: location,
        latitude: latitude,
        longitude: longitude,
        registered-at: stacks-block-height,
        active-policies: u0,
        total-premiums-paid: u0,
        total-claims-received: u0
      }
    )
    (ok true)
  )
)

;; Create insurance policy
(define-public (create-policy
  (coverage-type (string-ascii 20))
  (coverage-amount uint)
  (duration-blocks uint)
  (drought-threshold (optional uint))
  (flood-threshold (optional uint))
  (temp-min-threshold (optional int))
  (temp-max-threshold (optional int))
)
  (let
    (
      (caller tx-sender)
      (farmer-data (unwrap! (map-get? farmers caller) err-not-authorized))
      (policy-id (+ (var-get policy-nonce) u1))
      (premium (calculate-premium coverage-type coverage-amount duration-blocks))
      (current-block stacks-block-height)
    )
    (asserts! (or 
      (is-eq coverage-type coverage-drought)
      (or (is-eq coverage-type coverage-flood) (is-eq coverage-type coverage-temperature))
    ) err-invalid-coverage-type)
    (asserts! (and (> coverage-amount u0) (<= coverage-amount max-coverage-per-policy)) err-invalid-amount)
    (asserts! (> duration-blocks u0) err-invalid-amount)
    
    ;; Check if farmer can afford premium
    (asserts! (>= (stx-get-balance caller) premium) err-insufficient-funds)
    
    ;; Transfer premium to pool
    (try! (stx-transfer? premium caller (as-contract tx-sender)))
    
    ;; Create policy
    (map-set policies policy-id
      {
        farmer: caller,
        coverage-type: coverage-type,
        coverage-amount: coverage-amount,
        premium-paid: premium,
        start-block: current-block,
        end-block: (+ current-block duration-blocks),
        latitude: (get latitude farmer-data),
        longitude: (get longitude farmer-data),
        drought-threshold: drought-threshold,
        flood-threshold: flood-threshold,
        temp-min-threshold: temp-min-threshold,
        temp-max-threshold: temp-max-threshold,
        active: true,
        claim-paid: false,
        payout-amount: u0
      }
    )
    
    ;; Update farmer statistics
    (map-set farmers caller
      (merge farmer-data {
        active-policies: (+ (get active-policies farmer-data) u1),
        total-premiums-paid: (+ (get total-premiums-paid farmer-data) premium)
      })
    )
    
    ;; Update pool statistics
    (var-set policy-nonce policy-id)
    (var-set pool-balance (+ (var-get pool-balance) premium))
    (var-set total-coverage-outstanding (+ (var-get total-coverage-outstanding) coverage-amount))
    (var-set total-premiums-collected (+ (var-get total-premiums-collected) premium))
    
    (ok policy-id)
  )
)

;; Process weather-triggered claim (called by oracle)
(define-public (process-claim
  (policy-id uint)
  (event-type (string-ascii 20))
  (severity uint)
)
  (let
    (
      (policy (unwrap! (map-get? policies policy-id) err-policy-not-found))
      (payout-amount (calculate-payout (get coverage-amount policy) severity))
      (current-block stacks-block-height)
    )
    ;; Only oracle can trigger claims
    (asserts! (is-eq tx-sender (unwrap! (var-get oracle-contract) err-not-authorized)) err-not-authorized)
    (asserts! (get active policy) err-policy-expired)
    (asserts! (not (get claim-paid policy)) err-claim-already-paid)
    (asserts! (<= current-block (get end-block policy)) err-policy-expired)
    (asserts! (>= (var-get pool-balance) payout-amount) err-insufficient-pool-reserves)
    
    ;; Record weather event
    (map-set weather-events
      { policy-id: policy-id, event-block: current-block }
      {
        event-type: event-type,
        severity: severity,
        verified: true,
        payout-triggered: true,
        recorded-at: current-block
      }
    )
    
    ;; Update policy with claim payment
    (map-set policies policy-id
      (merge policy {
        claim-paid: true,
        payout-amount: payout-amount,
        active: false
      })
    )
    
    ;; Pay farmer
    (try! (as-contract (stx-transfer? payout-amount tx-sender (get farmer policy))))
    
    ;; Update pool and farmer statistics
    (var-set pool-balance (- (var-get pool-balance) payout-amount))
    (var-set total-claims-paid (+ (var-get total-claims-paid) payout-amount))
    (var-set total-coverage-outstanding (- (var-get total-coverage-outstanding) (get coverage-amount policy)))
    
    (let
      (
        (farmer-data (unwrap! (map-get? farmers (get farmer policy)) err-policy-not-found))
      )
      (map-set farmers (get farmer policy)
        (merge farmer-data {
          active-policies: (- (get active-policies farmer-data) u1),
          total-claims-received: (+ (get total-claims-received farmer-data) payout-amount)
        })
      )
    )
    
    (ok payout-amount)
  )
)

;; Add liquidity to insurance pool
(define-public (add-liquidity (amount uint))
  (let
    (
      (caller tx-sender)
      (current-provider (default-to 
        { total-deposited: u0, total-withdrawn: u0, deposit-block: u0, share-percentage: u0 }
        (map-get? liquidity-providers caller)
      ))
    )
    (asserts! (> amount u0) err-invalid-amount)
    (asserts! (>= (stx-get-balance caller) amount) err-insufficient-funds)
    
    ;; Transfer funds to pool
    (try! (stx-transfer? amount caller (as-contract tx-sender)))
    
    ;; Update provider record
    (map-set liquidity-providers caller
      {
        total-deposited: (+ (get total-deposited current-provider) amount),
        total-withdrawn: (get total-withdrawn current-provider),
        deposit-block: stacks-block-height,
        share-percentage: (calculate-pool-share caller amount)
      }
    )
    
    ;; Update pool balance
    (var-set pool-balance (+ (var-get pool-balance) amount))
    
    (ok amount)
  )
)

;; Set oracle contract (owner only)
(define-public (set-oracle-contract (oracle principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set oracle-contract (some oracle))
    (ok true)
  )
)

;; Read-only functions

;; Get farmer information
(define-read-only (get-farmer-info (farmer principal))
  (map-get? farmers farmer)
)

;; Get policy information
(define-read-only (get-policy-info (policy-id uint))
  (map-get? policies policy-id)
)

;; Get pool statistics
(define-read-only (get-pool-stats)
  {
    pool-balance: (var-get pool-balance),
    total-coverage: (var-get total-coverage-outstanding),
    total-premiums: (var-get total-premiums-collected),
    total-claims: (var-get total-claims-paid),
    utilization-ratio: (if (> (var-get pool-balance) u0)
      (/ (* (var-get total-coverage-outstanding) u100) (var-get pool-balance))
      u0
    )
  }
)

;; Get weather event information
(define-read-only (get-weather-event (policy-id uint) (event-block uint))
  (map-get? weather-events { policy-id: policy-id, event-block: event-block })
)

;; Check if policy is active and valid
(define-read-only (is-policy-active (policy-id uint))
  (match (map-get? policies policy-id)
    policy (and 
      (get active policy)
      (> (get end-block policy) stacks-block-height)
      (not (get claim-paid policy))
    )
    false
  )
)

;; Private functions

;; Calculate premium based on coverage type, amount and duration
(define-private (calculate-premium (coverage-type (string-ascii 20)) (amount uint) (duration uint))
  (let
    (
      (risk-multiplier (get-risk-multiplier coverage-type))
      (duration-factor (/ duration u1440)) ;; blocks to days approximation
      (base-premium (/ (* amount base-premium-rate) u10000))
    )
    (/ (* (* base-premium risk-multiplier) duration-factor) u100)
  )
)

;; Get risk multiplier for different coverage types
(define-private (get-risk-multiplier (coverage-type (string-ascii 20)))
  (if (is-eq coverage-type coverage-drought)
    u150 ;; 1.5x multiplier for drought
    (if (is-eq coverage-type coverage-flood)
      u200 ;; 2.0x multiplier for flood
      u120 ;; 1.2x multiplier for temperature
    )
  )
)

;; Calculate payout based on coverage amount and event severity
(define-private (calculate-payout (coverage-amount uint) (severity uint))
  (let
    (
      (severity-factor (if (> severity u100) u100 severity)) ;; cap at 100%
    )
    (/ (* coverage-amount severity-factor) u100)
  )
)

;; Calculate pool share percentage for liquidity provider
(define-private (calculate-pool-share (provider principal) (amount uint))
  (let
    (
      (total-pool (var-get pool-balance))
    )
    (if (> total-pool u0)
      (/ (* amount u100) total-pool)
      u100
    )
  )
)

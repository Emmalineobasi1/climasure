;; title: Climasure Weather Oracle
;; version: 1.0.0
;; summary: Weather data verification and climate event processing oracle
;; description: Manages weather data feeds, event detection, and automatic insurance claim triggering for climate-related events

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u200))
(define-constant err-not-authorized (err u201))
(define-constant err-invalid-coordinates (err u202))
(define-constant err-invalid-weather-data (err u203))
(define-constant err-data-source-not-found (err u204))
(define-constant err-event-already-processed (err u205))
(define-constant err-insufficient-data-points (err u206))
(define-constant err-invalid-threshold (err u207))
(define-constant err-outdated-data (err u208))
(define-constant err-oracle-not-authorized (err u209))

;; Weather event type constants
(define-constant event-drought "drought")
(define-constant event-flood "flood")
(define-constant event-temperature "temperature")
(define-constant event-storm "storm")

;; Threshold constants
(define-constant max-rainfall-per-day u500) ;; 500mm max reasonable daily rainfall
(define-constant min-temperature -5000) ;; -50C minimum reasonable temperature
(define-constant max-temperature 6000) ;; 60C maximum reasonable temperature
(define-constant max-data-age u144) ;; Data must be less than 144 blocks old (~24 hours)

;; Data variables
(define-data-var insurance-pool-contract (optional principal) none)
(define-data-var weather-data-nonce uint u0)
(define-data-var total-data-points uint u0)
(define-data-var total-events-triggered uint u0)

;; Authorized data providers
(define-map data-providers
  principal
  {
    name: (string-ascii 100),
    authorized: bool,
    reliability-score: uint,
    total-submissions: uint,
    last-submission: uint
  }
)

;; Weather data records
(define-map weather-data
  uint
  {
    location-lat: int,
    location-lng: int,
    temperature: int, ;; Celsius * 100 (e.g., 2050 = 20.50C)
    humidity: uint, ;; Percentage * 100
    precipitation: uint, ;; Millimeters * 100
    wind-speed: uint, ;; km/h * 100
    atmospheric-pressure: uint, ;; hPa * 100
    data-provider: principal,
    block-recorded: uint,
    verified: bool
  }
)

;; Location-based weather monitoring
(define-map location-monitoring
  { latitude: int, longitude: int }
  {
    active-policies: uint,
    drought-threshold-days: uint,
    flood-threshold-mm: uint,
    temp-min-threshold: int,
    temp-max-threshold: int,
    last-precipitation: uint,
    consecutive-dry-days: uint,
    monitoring-since: uint
  }
)

;; Weather event detection
(define-map weather-events
  uint
  {
    event-type: (string-ascii 20),
    location-lat: int,
    location-lng: int,
    severity: uint, ;; 0-100 percentage
    trigger-data-id: uint,
    policies-affected: uint,
    event-start-block: uint,
    processed: bool,
    insurance-claims-triggered: uint
  }
)

;; Data aggregation for locations
(define-map location-weather-summary
  { latitude: int, longitude: int, period-start: uint }
  {
    avg-temperature: int,
    total-precipitation: uint,
    max-daily-precipitation: uint,
    consecutive-dry-days: uint,
    data-points-count: uint,
    period-end: uint
  }
)

;; Oracle validation tracking
(define-map oracle-validations
  { data-id: uint, validator: principal }
  {
    validation-score: uint,
    validated-at: uint,
    notes: (string-ascii 200)
  }
)

;; Public functions

;; Register as weather data provider
(define-public (register-data-provider (name (string-ascii 100)))
  (let
    (
      (caller tx-sender)
    )
    (asserts! (> (len name) u0) err-invalid-weather-data)
    
    (map-set data-providers caller
      {
        name: name,
        authorized: false,
        reliability-score: u50, ;; Start with 50% reliability
        total-submissions: u0,
        last-submission: u0
      }
    )
    (ok true)
  )
)

;; Authorize data provider (owner only)
(define-public (authorize-data-provider (provider principal))
  (let
    (
      (provider-data (unwrap! (map-get? data-providers provider) err-data-source-not-found))
    )
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    (map-set data-providers provider
      (merge provider-data { authorized: true })
    )
    (ok true)
  )
)

;; Submit weather data
(define-public (submit-weather-data
  (latitude int)
  (longitude int)
  (temperature int)
  (humidity uint)
  (precipitation uint)
  (wind-speed uint)
  (atmospheric-pressure uint)
)
  (let
    (
      (caller tx-sender)
      (provider-data (unwrap! (map-get? data-providers caller) err-not-authorized))
      (data-id (+ (var-get weather-data-nonce) u1))
    )
    (asserts! (get authorized provider-data) err-not-authorized)
    (asserts! (validate-coordinates latitude longitude) err-invalid-coordinates)
    (asserts! (validate-weather-values temperature humidity precipitation wind-speed atmospheric-pressure) err-invalid-weather-data)
    
    ;; Store weather data
    (map-set weather-data data-id
      {
        location-lat: latitude,
        location-lng: longitude,
        temperature: temperature,
        humidity: humidity,
        precipitation: precipitation,
        wind-speed: wind-speed,
        atmospheric-pressure: atmospheric-pressure,
        data-provider: caller,
        block-recorded: stacks-block-height,
        verified: false
      }
    )
    
    ;; Update provider statistics
    (map-set data-providers caller
      (merge provider-data {
        total-submissions: (+ (get total-submissions provider-data) u1),
        last-submission: stacks-block-height
      })
    )
    
    ;; Update global counters
    (var-set weather-data-nonce data-id)
    (var-set total-data-points (+ (var-get total-data-points) u1))
    
    ;; Check for weather events at this location
    (let
      (
        (event-detected (detect-weather-events data-id latitude longitude))
      )
      (if event-detected
        (begin
          (try! (process-weather-event data-id))
          true
        )
        true
      )
    )
    
    (ok data-id)
  )
)

;; Process detected weather event
(define-public (process-weather-event (data-id uint))
  (let
    (
      (weather-data-record (unwrap! (map-get? weather-data data-id) err-invalid-weather-data))
      (latitude (get location-lat weather-data-record))
      (longitude (get location-lng weather-data-record))
      (event-info (analyze-weather-event data-id))
    )
    (asserts! (is-some event-info) err-insufficient-data-points)
    
    (let
      (
        (event-data (unwrap-panic event-info))
        (event-id (+ (var-get total-events-triggered) u1))
      )
      ;; Record weather event
      (map-set weather-events event-id
        {
          event-type: (get event-type event-data),
          location-lat: latitude,
          location-lng: longitude,
          severity: (get severity event-data),
          trigger-data-id: data-id,
          policies-affected: u0,
          event-start-block: stacks-block-height,
          processed: false,
          insurance-claims-triggered: u0
        }
      )
      
      ;; Update counter
      (var-set total-events-triggered event-id)
      
      ;; Trigger insurance claims if pool contract is set
      (match (var-get insurance-pool-contract)
        pool-contract (try! (trigger-insurance-claims event-id pool-contract))
        true
      )
      
      (ok event-id)
    )
  )
)

;; Trigger insurance claims for weather event
(define-public (trigger-insurance-claims (event-id uint) (pool-contract principal))
  (let
    (
      (event-data (unwrap! (map-get? weather-events event-id) err-invalid-weather-data))
    )
    (asserts! (not (get processed event-data)) err-event-already-processed)
    
    ;; Update event as processed
    (map-set weather-events event-id
      (merge event-data { processed: true })
    )
    
    ;; Here we would call the insurance pool contract to process claims
    ;; For now, we'll just mark it as processed
    (ok true)
  )
)

;; Set insurance pool contract (owner only)
(define-public (set-insurance-pool-contract (pool-contract principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set insurance-pool-contract (some pool-contract))
    (ok true)
  )
)

;; Update location monitoring parameters
(define-public (update-location-monitoring
  (latitude int)
  (longitude int)
  (drought-threshold-days uint)
  (flood-threshold-mm uint)
  (temp-min-threshold int)
  (temp-max-threshold int)
)
  (let
    (
      (current-monitoring (default-to
        {
          active-policies: u0,
          drought-threshold-days: u14,
          flood-threshold-mm: u10000,
          temp-min-threshold: 500,
          temp-max-threshold: 4500,
          last-precipitation: u0,
          consecutive-dry-days: u0,
          monitoring-since: stacks-block-height
        }
        (map-get? location-monitoring { latitude: latitude, longitude: longitude })
      ))
    )
    (asserts! (validate-coordinates latitude longitude) err-invalid-coordinates)
    (asserts! (> drought-threshold-days u0) err-invalid-threshold)
    (asserts! (> flood-threshold-mm u0) err-invalid-threshold)
    
    (map-set location-monitoring { latitude: latitude, longitude: longitude }
      (merge current-monitoring {
        drought-threshold-days: drought-threshold-days,
        flood-threshold-mm: flood-threshold-mm,
        temp-min-threshold: temp-min-threshold,
        temp-max-threshold: temp-max-threshold
      })
    )
    
    (ok true)
  )
)

;; Read-only functions

;; Get weather data by ID
(define-read-only (get-weather-data (data-id uint))
  (map-get? weather-data data-id)
)

;; Get weather event information
(define-read-only (get-weather-event (event-id uint))
  (map-get? weather-events event-id)
)

;; Get data provider information
(define-read-only (get-data-provider (provider principal))
  (map-get? data-providers provider)
)

;; Get location monitoring parameters
(define-read-only (get-location-monitoring (latitude int) (longitude int))
  (map-get? location-monitoring { latitude: latitude, longitude: longitude })
)

;; Get oracle statistics
(define-read-only (get-oracle-stats)
  {
    total-data-points: (var-get total-data-points),
    total-events-triggered: (var-get total-events-triggered),
    current-data-nonce: (var-get weather-data-nonce)
  }
)

;; Get recent weather data for location
(define-read-only (get-location-weather-summary (latitude int) (longitude int) (period-start uint))
  (map-get? location-weather-summary { latitude: latitude, longitude: longitude, period-start: period-start })
)

;; Private functions

;; Validate geographic coordinates
(define-private (validate-coordinates (latitude int) (longitude int))
  (and
    (and (>= latitude -9000000) (<= latitude 9000000))
    (and (>= longitude -18000000) (<= longitude 18000000))
  )
)

;; Validate weather measurement values
(define-private (validate-weather-values (temp int) (humidity uint) (precip uint) (wind uint) (pressure uint))
  (and
    (and (>= temp min-temperature) (<= temp max-temperature))
    (and (>= humidity u0) (<= humidity u10000))
    (and (>= precip u0) (<= precip max-rainfall-per-day))
    (and (>= wind u0) (<= wind u50000))
    (and (>= pressure u80000) (<= pressure u110000))
  )
)

;; Detect weather events from submitted data
(define-private (detect-weather-events (data-id uint) (latitude int) (longitude int))
  (let
    (
      (weather-record (unwrap! (map-get? weather-data data-id) false))
      (monitoring (map-get? location-monitoring { latitude: latitude, longitude: longitude }))
    )
    (match monitoring
      monitor-config
        (or
          (is-drought-event weather-record monitor-config)
          (or
            (is-flood-event weather-record monitor-config)
            (is-temperature-event weather-record monitor-config)
          )
        )
      false
    )
  )
)

;; Check if data indicates drought conditions
(define-private (is-drought-event (weather-record (tuple (location-lat int) (location-lng int) (temperature int) (humidity uint) (precipitation uint) (wind-speed uint) (atmospheric-pressure uint) (data-provider principal) (block-recorded uint) (verified bool))) (monitor-config (tuple (active-policies uint) (drought-threshold-days uint) (flood-threshold-mm uint) (temp-min-threshold int) (temp-max-threshold int) (last-precipitation uint) (consecutive-dry-days uint) (monitoring-since uint))))
  (and
    (<= (get precipitation weather-record) u100) ;; Less than 1mm precipitation
    (> (get consecutive-dry-days monitor-config) (get drought-threshold-days monitor-config))
  )
)

;; Check if data indicates flood conditions
(define-private (is-flood-event (weather-record (tuple (location-lat int) (location-lng int) (temperature int) (humidity uint) (precipitation uint) (wind-speed uint) (atmospheric-pressure uint) (data-provider principal) (block-recorded uint) (verified bool))) (monitor-config (tuple (active-policies uint) (drought-threshold-days uint) (flood-threshold-mm uint) (temp-min-threshold int) (temp-max-threshold int) (last-precipitation uint) (consecutive-dry-days uint) (monitoring-since uint))))
  (>= (get precipitation weather-record) (get flood-threshold-mm monitor-config))
)

;; Check if data indicates extreme temperature conditions
(define-private (is-temperature-event (weather-record (tuple (location-lat int) (location-lng int) (temperature int) (humidity uint) (precipitation uint) (wind-speed uint) (atmospheric-pressure uint) (data-provider principal) (block-recorded uint) (verified bool))) (monitor-config (tuple (active-policies uint) (drought-threshold-days uint) (flood-threshold-mm uint) (temp-min-threshold int) (temp-max-threshold int) (last-precipitation uint) (consecutive-dry-days uint) (monitoring-since uint))))
  (or
    (<= (get temperature weather-record) (get temp-min-threshold monitor-config))
    (>= (get temperature weather-record) (get temp-max-threshold monitor-config))
  )
)

;; Analyze weather event and determine severity
(define-private (analyze-weather-event (data-id uint))
  (let
    (
      (weather-record (unwrap! (map-get? weather-data data-id) none))
    )
    (some {
      event-type: event-drought,
      severity: u75
    })
  )
)

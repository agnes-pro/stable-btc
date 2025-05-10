;; StableBTC: Bitcoin-Backed Stablecoin Lending Protocol
;; Secure Over-Collateralized Debt Positions with BTC Collateralization
;; Decentralized protocol enabling BTC holders to mint stablecoins while maintaining collateralized debt positions.
;; Features automated liquidations, real-time risk management, and interest rate accrual.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u1000))
(define-constant ERR-INSUFFICIENT-COLLATERAL (err u1001))
(define-constant ERR-POSITION-NOT-FOUND (err u1002))
(define-constant ERR-UNDERCOLLATERALIZED (err u1003))
(define-constant ERR-MINIMUM-LOAN-REQUIRED (err u1004))
(define-constant ERR-INSUFFICIENT-DEBT (err u1005))
(define-constant ERR-PRICE-EXPIRED (err u1006))
(define-constant ERR-PROTOCOL-PAUSED (err u1007))
(define-constant ERR-INVALID-AMOUNT (err u1008))

;; Protocol parameters
(define-constant COLLATERAL-RATIO u150) ;; 150% minimum collateral ratio (1.5x)
(define-constant LIQUIDATION-THRESHOLD u120) ;; 120% liquidation threshold
(define-constant LIQUIDATION-PENALTY u10) ;; 10% liquidation penalty
(define-constant MINIMUM_LOAN_AMOUNT u100000000) ;; 100 stablecoins (with 8 decimals)
(define-constant PRICE_EXPIRY u86400) ;; Price feed valid for 24 hours (in seconds)
(define-constant INTEREST_RATE_PER_BLOCK u5) ;; 0.0005% interest per block (approx 10% APR)
(define-constant INTEREST_RATE_DENOMINATOR u1000000) ;; Interest rate precision

;; Data maps and variables
(define-data-var protocol-owner principal tx-sender)
(define-data-var protocol-paused bool false)
(define-data-var total-debt uint u0) ;; Total debt in the system
(define-data-var total-collateral uint u0) ;; Total BTC collateral in the system
(define-data-var stability-fee uint u0) ;; Accumulated fees
(define-data-var last-accrual-block uint stacks-block-height) ;; Last interest accrual block
(define-data-var btc-price-in-usd (optional {price: uint, timestamp: uint}) none) ;; BTC/USD price from oracle

;; User positions tracking
(define-map positions principal {
  collateral: uint,  ;; Amount of BTC collateral (in satoshis)
  debt: uint,        ;; Amount of stablecoin debt
  last-update-block: uint  ;; Last block when position was updated (for interest calculation)
})

;; FT for stablecoin token
(define-fungible-token stable-usd)

;; Administrative functions
(define-public (set-protocol-owner (new-owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get protocol-owner)) ERR-NOT-AUTHORIZED)
    (ok (var-set protocol-owner new-owner))
  )
)

(define-public (pause-protocol (paused bool))
  (begin
    (asserts! (is-eq tx-sender (var-get protocol-owner)) ERR-NOT-AUTHORIZED)
    (ok (var-set protocol-paused paused))
  )
)

(define-public (update-btc-price (price uint) (timestamp uint))
  (begin
    (asserts! (is-eq tx-sender (var-get protocol-owner)) ERR-NOT-AUTHORIZED)
    (asserts! (> price u0) ERR-INVALID-AMOUNT)
    (var-set btc-price-in-usd (some {price: price, timestamp: timestamp}))
    (ok true)
  )
)

;; Utility functions
(define-private (collateral-value (collateral-amount uint) (price uint))
  (* collateral-amount price)
)

(define-private (required-collateral (debt-amount uint) (price uint))
  (/ (* debt-amount COLLATERAL-RATIO) (/ price u100))
)

(define-private (is-position-safe (user principal) (btc-price uint))
  (let (
    (position (unwrap! (map-get? positions user) false))
    (debt (get debt position))
    (collateral (get collateral position))
    (collateral-value-usd (collateral-value collateral btc-price))
    (min-collateral-value-usd (/ (* debt COLLATERAL-RATIO) u100))
  )
  (>= collateral-value-usd min-collateral-value-usd))
)

(define-private (calculate-interest (debt uint) (blocks-passed uint))
  (/ (* debt (* blocks-passed INTEREST_RATE_PER_BLOCK)) INTEREST_RATE_DENOMINATOR)
)

(define-private (accrue-global-interest)
  (let (
    (current-block stacks-block-height)
    (last-block (var-get last-accrual-block))
    (blocks-passed (- current-block last-block))
    (total-system-debt (var-get total-debt))
    (interest-accrued (calculate-interest total-system-debt blocks-passed))
  )
    (begin
      (if (> blocks-passed u0)
        (begin
          (var-set stability-fee (+ (var-get stability-fee) interest-accrued))
          (var-set total-debt (+ total-system-debt interest-accrued))
          (var-set last-accrual-block current-block)
        )
        false
      )
      true
    )
  )
)

(define-private (accrue-position-interest (user principal))
  (let (
    (position (unwrap! (map-get? positions user) false))
    (debt (get debt position))
    (collateral (get collateral position))
    (last-update (get last-update-block position))
    (blocks-passed (- stacks-block-height last-update))
    (interest-accrued (calculate-interest debt blocks-passed))
    (new-debt (+ debt interest-accrued))
  )
    (begin
      (if (> blocks-passed u0)
        (begin
          (map-set positions user {
            collateral: collateral,
            debt: new-debt,
            last-update-block: stacks-block-height
          })
        )
        false
      )
      {debt: new-debt, collateral: collateral}
    )
  )
)

(define-private (get-current-price)
  (let (
    (price-data (unwrap! (var-get btc-price-in-usd) ERR-PRICE-EXPIRED))
    (price (get price price-data))
    (timestamp (get timestamp price-data))
  )
    (begin
      (asserts! (< (- block-timestamp timestamp) PRICE_EXPIRY) ERR-PRICE-EXPIRED)
      (asserts! (> price u0) ERR-PRICE-EXPIRED)
      price
    )
  )
)

;; Core user functions
(define-public (create-position (btc-amount uint) (stable-amount uint))
  (let (
    (btc-price (get-current-price))
    (user tx-sender)
    (existing-position (map-get? positions user))
  )
    (begin
      (asserts! (not (var-get protocol-paused)) ERR-PROTOCOL-PAUSED)
      (asserts! (>= btc-amount u0) ERR-INVALID-AMOUNT)
      (asserts! (>= stable-amount MINIMUM_LOAN_AMOUNT) ERR-MINIMUM-LOAN-REQUIRED)
      
      ;; Update global interest
      (accrue-global-interest)
      
      ;; Check if user already has a position and update it with interest
      (if (is-some existing-position)
        (accrue-position-interest user)
        false
      )
      
      ;; Calculate total position after adding new collateral and debt
      (let (
        (old-collateral (if (is-some existing-position) (get collateral (unwrap-panic existing-position)) u0))
        (old-debt (if (is-some existing-position) (get debt (unwrap-panic existing-position)) u0))
        (new-collateral (+ old-collateral btc-amount))
        (new-debt (+ old-debt stable-amount))
        (min-required-collateral (required-collateral new-debt btc-price))
      )
        (begin
          ;; Check collateralization
          (asserts! (>= (collateral-value new-collateral btc-price) min-required-collateral) ERR-INSUFFICIENT-COLLATERAL)
          
          ;; Update position
          (map-set positions user {
            collateral: new-collateral,
            debt: new-debt,
            last-update-block: stacks-block-height
          })
          
          ;; Update totals
          (var-set total-collateral (+ (var-get total-collateral) btc-amount))
          (var-set total-debt (+ (var-get total-debt) stable-amount))
          
          ;; Mint stablecoins to user
          (ft-mint? stable-usd stable-amount user)
        )
      )
    )
  )
)

(define-public (add-collateral (btc-amount uint))
  (let (
    (user tx-sender)
    (position (unwrap! (map-get? positions user) ERR-POSITION-NOT-FOUND))
    (old-collateral (get collateral position))
    (debt (get debt position))
  )
    (begin
      (asserts! (not (var-get protocol-paused)) ERR-PROTOCOL-PAUSED)
      (asserts! (> btc-amount u0) ERR-INVALID-AMOUNT)
      
      ;; Update global interest
      (accrue-global-interest)
      
      ;; Update position with accrued interest
      (let (
        (updated-position (accrue-position-interest user))
        (new-debt (get debt updated-position))
        (old-collateral (get collateral updated-position))
        (new-collateral (+ old-collateral btc-amount))
      )
        (begin
          ;; Update position
          (map-set positions user {
            collateral: new-collateral,
            debt: new-debt,
            last-update-block: stacks-block-height
          })
          
          ;; Update totals
          (var-set total-collateral (+ (var-get total-collateral) btc-amount))
          
          (ok true)
        )
      )
    )
  )
)

(define-public (repay-debt (amount uint))
  (let (
    (user tx-sender)
    (position (unwrap! (map-get? positions user) ERR-POSITION-NOT-FOUND))
  )
    (begin
      (asserts! (not (var-get protocol-paused)) ERR-PROTOCOL-PAUSED)
      (asserts! (> amount u0) ERR-INVALID-AMOUNT)
      
      ;; Update global interest
      (accrue-global-interest)
      
      ;; Update position with accrued interest
      (let (
        (updated-position (accrue-position-interest user))
        (current-debt (get debt updated-position))
        (collateral (get collateral updated-position))
        (repay-amount (if (> amount current-debt) current-debt amount))
        (new-debt (- current-debt repay-amount))
      )
        (begin
          (asserts! (<= repay-amount current-debt) ERR-INSUFFICIENT-DEBT)
          
          ;; Burn stablecoins from user
          (try! (ft-burn? stable-usd repay-amount user))
          
          ;; Update position
          (if (is-eq new-debt u0)
            ;; If debt is fully repaid, return all collateral and delete position
            (begin
              (map-delete positions user)
              (var-set total-collateral (- (var-get total-collateral) collateral))
            )
            ;; Otherwise update the position with reduced debt
            (map-set positions user {
              collateral: collateral,
              debt: new-debt,
              last-update-block: stacks-block-height
            })
          )
          
          ;; Update total debt
          (var-set total-debt (- (var-get total-debt) repay-amount))
          
          (ok true)
        )
      )
    )
  )
)
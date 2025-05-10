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
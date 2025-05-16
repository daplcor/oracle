(module oracle GOV
  "A trusted oracle system with multiple reporters and median aggregation, obviously ;)"

(use free.util-math [med is-even med* min-list max-list])
(use free.util-time)
(use free.util-random)
(use free.util-lists)

;; Capabilities

(defcap GOV ()
    (enforce-keyset "ORACLE_NS.GOV"))

(defcap OPS ()
    (enforce-keyset "ORACLE_NS.OPS"))

 (defcap REPORTER (reporter:string)
    @doc "Capability for an approved reporter to submit data"
    (with-read reporters reporter
      { 'guard := g }
      (enforce-guard g)))

(defcap UPDATE_REPORTS ()
    @doc "Internal capability to update reports" true)

;; Schemas

(defschema oracle-result
    timestamp:time
    value:decimal)

(defschema report-schema
    reporter:string
    symbol:string
    timestamp:time
    value:decimal)

(defschema reporter
    description:string
    guard:guard
    next-report-time:time
    is-active:bool)

(defschema symbol-config
    avg-interval:decimal        ;; T-bar: Average reporting interval
    max-deviation:decimal       ;; delta-t: Maximum deviation in timing
    aggregation-count:integer   ;; N: Number of reports for aggregation
    is-active:bool)

(defschema recent-reports
  reports:[string])

;; Tables

(deftable oracle:{oracle-result})
(deftable reports:{report-schema})
(deftable reporters:{reporter})
(deftable symbols:{symbol-config})
(deftable recent-reports-table:{recent-reports})

;; Key Functions

(defun add-symbol:string (symbol:string avg-interval:decimal max-deviation:decimal aggregation-count:integer)
  @doc "Add a new symbol to the oracle"

  (with-capability (OPS)
    (insert symbols symbol
      { 'avg-interval: avg-interval
      , 'max-deviation: max-deviation
      , 'aggregation-count: aggregation-count
      , 'is-active: true })

    (insert oracle symbol
      { 'timestamp: (now)
      , 'value: 0.0 })

    (insert recent-reports-table symbol
      { 'reports: [] })))

(defun submit-report:string (symbol:string reporter:string value:decimal)
  @doc "Submit a price report for a symbol"

  ;; Check if symbol and reporter are active
  (enforce-active-symbol symbol)
  (enforce-active-reporter reporter)
  (enforce-check-reporter-time reporter)
  (enforce (> value 0.0) "Value must be greater than 0.0")

      (with-capability (REPORTER reporter)
          ;; Calculate and Update reporter's next report time
          (update reporters reporter
            { 'next-report-time: (calculate-next-report-time symbol) })

            ;; Store the report
            (insert reports (format "{}-{}-{}" [symbol reporter (now)])
            { 'symbol: symbol
            , 'reporter: reporter
            , 'timestamp: (now)
            , 'value: value })

        ;; Update recent reports list
        (with-capability (UPDATE_REPORTS)
        (update-recent-reports symbol (format "{}-{}-{}" [symbol reporter (now)]))

        ;; Update oracle value with latest reports
        (update-oracle-value symbol))))

(defun update-recent-reports:string (symbol:string report:string)
  @doc "Add a report ID to the recent reports list for a symbol"
  (require-capability (UPDATE_REPORTS))
  (with-read symbols symbol
    { 'aggregation-count := agg-count }

    (with-read recent-reports-table symbol
      { 'reports := current-reports }

        ;; Using util-lists fifo-push to maintain a fixed-size list
        (write recent-reports-table symbol
          { 'reports: (fifo-push current-reports agg-count report) }))))

;; I could break out median-value into a separate function, but it is only used here
(defun update-oracle-value:string (symbol:string)
  @doc "Update the oracle value using median of recent reports"
    (require-capability (UPDATE_REPORTS))
    (enforce-recent-reports symbol)

        (let
          ((recent-reports (get-recent-reports symbol))
           ;; We have to extract values as decimals for med functions
           (values:[decimal] (map (lambda (r) (at 'value r)) recent-reports))

           ;; Calculates the median price
           (median-value:decimal (if (is-even (length values))
                                   (med* values)
                                   (med values))))

          ;; Update the truthful oracle value
          (write oracle symbol
            { 'timestamp: (now)
            , 'value: median-value })))

(defun update-symbol-status:string (symbol:string is-active:bool)
  @doc "Update the active status of a symbol"
  (with-capability (OPS)
    (update symbols symbol
      { 'is-active: is-active })))

;; Reporter Management

;; We could change this to write and have one function vs two, but is built with a purpose here
(defun add-reporter:string (reporter:string description:string g:guard)
   @doc "Add or Update a reporter"
  (with-capability (OPS)
    (insert reporters reporter
    { 'description: description
    , 'guard: g
    , 'next-report-time: EPOCH
    , 'is-active: true
    })))

(defun update-reporter-status:string (reporter:string is-active:bool)
    @doc "Update the active status of a reporter"
    (with-capability (OPS)
        (update reporters reporter
        { 'is-active: is-active })))


(defun get-recent-reports:[object{report-schema}] (symbol:string)
  @doc "Get recent reports for a symbol using the index"
  (with-read recent-reports-table symbol
    { 'reports := report-ids }
    (map (lambda (id) (read reports id)) report-ids)))

;; Helper Functions

(defun get-price:object{oracle-result} (symbol:string)
    @doc "Get the current price for a symbol"
    (read oracle symbol))

(defun check-reporter-time:string (reporter:string)
  @doc "Check if reporter can submit now"
  (with-read reporters reporter
    { 'next-report-time := next-time }
      (format "Next report time for {} is {}" [reporter next-time])))

(defun calculate-next-report-time:time (symbol:string)
  @doc "Calculate the next report time with randomization"
  (with-read symbols symbol
    { 'avg-interval := avg-interval
    , 'max-deviation := max-deviation }
    (add-time (now) (+ avg-interval (random-decimal-range (- max-deviation) max-deviation)))))

;; Validation Functions

(defun enforce-active-symbol:bool (symbol:string)
    @doc "Enforce that the symbol is active"
    (with-read symbols symbol
        { 'is-active := is-active }
        (enforce is-active "Symbol is not active")))

(defun enforce-active-reporter:bool (reporter:string)
    @doc "Enforce that the reporter is active"
    (with-read reporters reporter
        { 'is-active := is-active }
        (enforce is-active "Reporter is not active")))

(defun enforce-check-reporter-time:bool (reporter:string)
  @doc "Check if reporter can submit now"
  (with-read reporters reporter
    { 'next-report-time := next-time }
      (enforce (>= (now) next-time)
        "Too early to report")))

(defun enforce-recent-reports:bool (symbol:string)
  @doc "Enforce that there are recent reports for a symbol"
    (let ((recent-reports (get-recent-reports symbol)))
    (enforce (> (length recent-reports) 0) "No recent reports available")))
)

(create-table oracle)
(create-table reports)
(create-table reporters)
(create-table symbols)
(create-table recent-reports-table)

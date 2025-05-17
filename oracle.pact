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

 (defcap REPORTER (reporter:string symbol:string)
    @doc "Capability for an approved reporter to submit data"
    (with-read reporters (reporter-key reporter symbol)
      { 'guard := g }
      (enforce-guard g)))

(defcap UPDATE_REPORTS ()
    @doc "Internal capability to update reports" true)

(defcap UPDATE_REPORTERS ()
    @doc "Internal capability to update reporters" true)

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
    @doc "reporter-key is a unique key for the reporter and symbol"
    description:string
    guard:guard
    next-report-time:time
    is-active:bool)

(defschema symbol-config
    avg-interval:decimal        ;; T-bar: Average reporting interval
    max-deviation:decimal       ;; delta-t: Maximum deviation in timing
    aggregation-count:integer   ;; N: Number of reports for aggregation
    is-active:bool)

(defschema recent-reports-schema
    @doc "List of recent reports for a symbol"
    reports:[string])

(defschema symbol-reporters-schema
    @doc "List of reporters for a symbol"
    reporters:[string])

;; Tables

(deftable reports:{report-schema})
(deftable reporters:{reporter})
(deftable symbols:{symbol-config})
(deftable recent-reports:{recent-reports-schema})
(deftable symbol-reporters:{symbol-reporters-schema})

;; Key Functions

(defun add-symbol:string (symbol:string avg-interval:decimal max-deviation:decimal aggregation-count:integer)
  @doc "Add a new symbol to the oracle"

  (with-capability (OPS)
    (insert symbols symbol
      { 'avg-interval: avg-interval
      , 'max-deviation: max-deviation
      , 'aggregation-count: aggregation-count
      , 'is-active: true })

    (insert recent-reports symbol
      { 'reports: [] })

    (insert symbol-reporters symbol
    { 'reporters: [] })))

(defun submit-report:string (symbol:string reporter:string value:decimal)
  @doc "Submit a price report for a symbol"

  ;; Check if symbol and reporter are active
  (enforce-active-symbol symbol)
  (enforce-active-reporter reporter symbol)
  (enforce-check-reporter-time reporter symbol)
  (enforce (> value 0.0) "Value must be greater than 0.0")

      (with-capability (REPORTER reporter symbol)
          ;; Calculate and Update reporter's next report time
          (update reporters (reporter-key reporter symbol)
            { 'next-report-time: (calculate-next-report-time symbol) })

            ;; Store the report
            (insert reports (format "{}-{}-{}" [symbol reporter (now)])
            { 'symbol: symbol
            , 'reporter: reporter
            , 'timestamp: (now)
            , 'value: value })

        ;; Update recent reports list
        (with-capability (UPDATE_REPORTS)
        (update-recent-reports symbol (format "{}-{}-{}" [symbol reporter (now)])))

        (with-capability (UPDATE_REPORTERS)
        (if (check-reporter-list reporter symbol)
        "Already exists in the list"
         (update-reporter-list reporter symbol))))
         "Report submitted successfully")

(defun update-recent-reports:string (symbol:string report:string)
  @doc "Add a report ID to the recent reports list for a symbol"
  (require-capability (UPDATE_REPORTS))
  (with-read symbols symbol
    { 'aggregation-count := agg-count }

    (with-read recent-reports symbol
      { 'reports := current-reports }

        ;; Using util-lists fifo-push to maintain a fixed-size list
        (write recent-reports symbol
          { 'reports: (fifo-push current-reports agg-count report) }))))

(defun update-symbol-status:string (symbol:string is-active:bool)
  @doc "Update the active status of a symbol"
  (with-capability (OPS)
    (update symbols symbol
      { 'is-active: is-active })))

;; Reporter Management

;; We could change this to write and have one function vs two, but is built with a purpose here
(defun add-reporter:string (reporter:string symbol:string description:string g:guard)
   @doc "Add or Update a reporter"

   (with-read symbol-reporters symbol
      { 'reporters := current-reporters }

  (with-capability (OPS)
    (insert reporters (reporter-key reporter symbol)
    { 'description: description
    , 'guard: g
    , 'next-report-time: EPOCH
    , 'is-active: true
    }))))

(defun update-reporter-status:string (reporter:string symbol:string is-active:bool)
    @doc "Update the active status of a reporter"
    (with-capability (OPS)
        (update reporters (reporter-key reporter symbol)
        { 'is-active: is-active }))
        ;; Remove from symbol list if being deactivated
        (if (not is-active)
            (with-capability (UPDATE_REPORTERS)
                (remove-reporter-from-list reporter symbol))
            "Reporter status updated"))

(defun get-recent-reports:[object{report-schema}] (symbol:string)
  @doc "Get recent reports for a symbol using the index"
  (with-read recent-reports symbol
    { 'reports := r-id }
        (map (read reports) r-id)))

(defun update-reporter-list:string (reporter:string symbol:string)
  @doc "Updates the reporter list for a symbol"
  (require-capability (UPDATE_REPORTERS))
    (with-read symbol-reporters symbol
      { 'reporters := current-reporters }
        (update symbol-reporters symbol
          { 'reporters: (+ current-reporters [reporter]) })))

(defun remove-reporter-from-list:string (reporter:string symbol:string)
    @doc "Remove a reporter from the symbol's reporter list"
    (require-capability (UPDATE_REPORTERS))
    (with-read symbol-reporters symbol
        { 'reporters := current-reporters }
        (update symbol-reporters symbol
            { 'reporters: (filter (!= reporter) current-reporters) })))

;; Helper Functions

(defun check-reporter-list:bool (reporter:string symbol:string)
  @doc "Check if reporter is attached to this symbol"
  (with-read symbol-reporters symbol
    { 'reporters := current-reporters }
    (contains reporter current-reporters)))

(defun get-price:object{oracle-result} (symbol:string)
    @doc "Get the current price for a symbol"
    (enforce-recent-reports symbol)

        (let ((recent-reports (get-recent-reports symbol))
           ;; We have to extract values as decimals for med functions
           (values:[decimal] (map (at 'value ) recent-reports)))

            ;; Computes the real time price
            { 'timestamp: (at 'timestamp (at 0 recent-reports))
            , 'value: (med* values) }))

(defun check-reporter-time:time (reporter:string symbol:string)
  @doc "Check if reporter can submit now"
  (with-read reporters (reporter-key reporter symbol)
    { 'next-report-time := next-time }
      next-time))

(defun calculate-next-report-time:time (symbol:string)
  @doc "Calculate the next report time with randomization"
  (with-read symbols symbol
    { 'avg-interval := avg-interval
    , 'max-deviation := max-deviation }
    (add-time (now) (+ avg-interval (random-decimal-range (- max-deviation) max-deviation)))))

(defun reporter-key:string (reporter:string symbol:string)
  @doc "Generate a unique key for the reporter and symbol"
  (format "{}:{}" [reporter symbol]))

(defun get-symbol-reporters:object (symbol:string)
  @doc "Check if reporter is attached to this symbol"
  (read symbol-reporters symbol))

;; Validation Functions

(defun enforce-active-symbol:bool (symbol:string)
    @doc "Enforce that the symbol is active"
    (with-read symbols symbol
        { 'is-active := is-active }
        (enforce is-active "Symbol is not active")))

(defun enforce-active-reporter:bool (reporter:string symbol:string)
    @doc "Enforce that the reporter is active"
    (with-read reporters (reporter-key reporter symbol)
        { 'is-active := is-active }
        (enforce is-active "Reporter is not active")))

(defun enforce-check-reporter-time:bool (reporter:string symbol:string)
  @doc "Check if reporter can submit now"
  (with-read reporters (reporter-key reporter symbol)
    { 'next-report-time := next-time }
      (enforce (>= (now) next-time)
        "Too early to report")))

(defun enforce-recent-reports:bool (symbol:string)
  @doc "Enforce that there are recent reports for a symbol"
    (let ((recent-reports (get-recent-reports symbol)))
    (enforce (> (length recent-reports) 0) "No recent reports available")))
)

(create-table reports)
(create-table reporters)
(create-table symbols)
(create-table recent-reports)
(create-table symbol-reporters)

(module oracle GOV
  "A trusted oracle system with multiple reporters and median aggregation, obviously ;)"

(use free.util-math [med is-even med* min-list max-list])
(use free.util-time)
(use free.util-random)
(use free.util-lists)
(use free.util-strings)
(use free.util-fungible)

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

;; Schemas

(defschema oracle-result
    timestamp:time
    value:decimal)

(defschema report-schema
    timestamp:time
    value:decimal)

(defschema reporter-schema
    @doc "reporter-key is a unique key for the reporter and symbol"
    description:string
    guard:guard
    next-report-time:time
    last-report-id:string
    is-active:bool)

(defschema symbol-config
    @doc "symbol name is a unique key"
    avg-interval:decimal        ;; T-bar: Average reporting interval
    max-deviation:decimal       ;; delta-t: Maximum deviation in timing
    aggregation-count:integer   ;; N: Number of reports for aggregation
    is-active:bool)

(defschema recent-reports-schema
  reports:[string])

;; Tables

(deftable reports:{report-schema})
(deftable reporters:{reporter-schema})
(deftable symbols:{symbol-config})
(deftable recent-reports:{recent-reports-schema})

;; Main Functions

(defun init:string ()
  @doc "Initialize the oracle system"
    (insert reports "" { 'timestamp: EPOCH, 'value: 0.0 }))

(defun submit-report:string (symbol:string reporter:string value:decimal)
  @doc "Submit a price report for a symbol"

  ;; Check if symbol and reporter are active
  (enforce-active-symbol symbol)
  (enforce-active-reporter reporter symbol)
  (enforce-check-reporter-time reporter symbol)
  (enforce (> value 0.0) "Value must be greater than 0.0")

      (with-capability (REPORTER reporter symbol)
      (let ((r-id:string (format "{}:{}:{}" [symbol reporter (now)])))
          ;; Calculate and Update reporter's next report time
          (update reporters (reporter-key reporter symbol)
            { 'next-report-time: (calculate-next-report-time symbol)
            , 'last-report-id: r-id })

            ;; Store the report
            (insert reports r-id
            {
              'timestamp: (now)
            , 'value: value })

        ;; Update recent reports list
        (with-capability (UPDATE_REPORTS)
        (update-recent-reports symbol r-id)))))

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

(defun update-symbol:string (symbol:string avg-interval:decimal max-deviation:decimal aggregation-count:integer is-active:bool)
  @doc "Add or Update the symbol configuration"
  (enforce-symbol-numbers avg-interval max-deviation aggregation-count)

  (with-capability (OPS)
    (write symbols symbol
      { 'avg-interval: avg-interval
      , 'max-deviation: max-deviation
      , 'aggregation-count: aggregation-count
      , 'is-active: is-active })

       ;; If aggregation count decreased, trim the recent reports list
        (with-default-read recent-reports symbol
         { 'reports : [] } { 'reports := current-reports }
          (write recent-reports symbol
            { 'reports: (take (- aggregation-count) current-reports) }))))

;; Reporter Management

(defun add-reporter:string (reporter:string symbol:string description:string g:guard)
   @doc "Add or Update a reporter"
   (enforce-reserved reporter g)
   (with-capability (OPS)
    (insert reporters (reporter-key reporter symbol)
    { 'description: description
    , 'guard: g
    , 'next-report-time: EPOCH
    , 'last-report-id: ""
    , 'is-active: true
    })))

(defun update-reporter-status:string (reporter:string symbol:string is-active:bool)
    @doc "Update the active status of a reporter"
    (with-capability (OPS)
        (update reporters (reporter-key reporter symbol)
        { 'is-active: is-active })

        ; In case a reporter is disabled remove its recent reports immediately
        (with-read reporters (reporter-key reporter symbol) {'last-report-id := last-report-id}
          (with-read recent-reports symbol {'reports := current-reports}
            (update recent-reports symbol
              {'reports: (remove-item current-reports (if (not is-active) last-report-id ""))})))))


(defun get-recent-reports:[object{report-schema}] (symbol:string)
  @doc "Get recent reports for a symbol using the index"
  (with-read recent-reports symbol
    { 'reports := r-id }
        (map (read reports) r-id)))

;; Helper Functions

(defun get-price:object{oracle-result} (symbol:string)
    @doc "Get the current price for a symbol"
    (enforce-recent-reports symbol)

        (let ((recent-reports (get-recent-reports symbol))
           ;; We have to extract values as decimals for med functions
           (values:[decimal] (map (at 'value ) recent-reports)))

            ;; Computes the real time price
            { 'timestamp: (at 'timestamp (at 0 recent-reports))
            , 'value: (med* values) }))

(defun reporter-info:object{reporter-schema} (reporter:string symbol:string)
  @doc "Returns the reporter information"
  (read reporters (reporter-key reporter symbol)))

(defun check-reporter-time:time (reporter:string symbol:string)
  @doc "Check if reporter can submit now"
  (with-read reporters (reporter-key reporter symbol)
    { 'next-report-time := next-time }
      next-time))

(defun reporter-health-check:bool (reporter:string symbol:string)
  @doc "Check if the reporter is healthy (reported within 3 minutes of check in)"
    (<= (diff-time (now) (check-reporter-time reporter symbol)) (minutes 3.0)))

(defun get-report-time:time (report-id:string)
  @doc "Get the last report time for a given report ID"
    (at 'timestamp (read reports report-id)))

(defun calculate-next-report-time:time (symbol:string)
  @doc "Calculate the next report time with randomization"
  (with-read symbols symbol
    { 'avg-interval := avg-interval
    , 'max-deviation := max-deviation }
    (add-time (now) (+ avg-interval (random-decimal-range (- max-deviation) max-deviation)))))

(defun get-reporters-by-symbol (symbol:string)
    @doc "Get all reporters for a given symbol, local call only due to gas"
   (fold-db reporters (lambda (k obj) (and (ends-with k symbol) (at 'is-active obj) ))
                      (lambda (k obj) (+ obj {'reporter: k, 'last-report: (read reports (at 'last-report-id obj))}))))


(defun reporter-key:string (reporter:string symbol:string)
  @doc "Generate a unique key for the reporter and symbol"
  (format "{}:{}" [reporter symbol]))

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

(defun enforce-symbol-numbers:bool (avg-interval:decimal max-deviation:decimal aggregation-count:integer)
  @doc "Enforce that a decimal is a number and an integer is a number"
    (enforce (> avg-interval 0.0) "Average interval must be greater than 0.0")
    (enforce (> max-deviation 0.0) "Max deviation must be greater than 0.0")
    (enforce (> aggregation-count 0) "Aggregation count must be greater than 0"))

)

(create-table reports)
(create-table reporters)
(create-table symbols)
(create-table recent-reports)
(init)
;;;; initial-rewiring.lisp
;;;;
;;;; Author: Corwin de Boor
;;;;
;;;; We attempt to make an intelligent guess for what the initial rewiring
;;;; should be for the quil program. This does some checks that the used qubits
;;;; can fit on the chip's connected components compatibly, or greedily
;;;; reassigns the qubits close to where they will be needed first.

(in-package #:cl-quil)

(defparameter *initial-rewiring-default-type* ':partial
  "Determines the default initial rewiring type when not provided and PROG-INITIAL-REWIRING-HEURISTIC cannot determine that a NAIVE rewiring is \"safe\".

PARTIAL: Start with a completely empty rewiring.
GREEDY: Attempt to rewire greedily based on distance of 2-qubit gates.
RANDOM: Start with a random rewiring.
NAIVE: Start with the identity rewiring. This will fail if any 2-qubit gates are
impossible using that rewiring.")


;;; a minimalist queue implementation ;;;
(defun make-q (&rest items)
  (let ((dummy (list nil)))
    (list* (nconc items dummy) dummy)))
(defun q-empty (q)
  (eql (car q) (cdr q)))
(defun q-enq (el q)
  (setf (cadr q) el
        (cddr q) (list nil)
        (cdr q) (cddr q))
  q)
(defun q-deq (q)
  (if (q-empty q) nil (pop (car q))))


(defun chip-spec-live-qubit-bfs (chip-spec qubit-index &optional seen)
  "From a given initial qubit, find the distance to every other qubit in the connected component. SEEN is an array of T/NIL for each qubit, indicating whether that qubit has been visited yet."
  (assert (not (chip-spec-qubit-dead? chip-spec qubit-index)) (qubit-index)
          "Cannot BFS from dead qubit ~A."
          qubit-index)
  (loop
    :with level := 0
    :and seen := (or seen (make-array (chip-spec-n-qubits chip-spec) :initial-element nil))

    ;; this uses a trick where a special nil token signifies we have reached the
    ;; next level of the bfs
    :and queue := (make-q qubit-index nil)
           :initially (setf (aref seen qubit-index) t)

    :for cur := (q-deq queue)
    :until (q-empty queue) ; if empty, only special token was left

    :if cur
      ;; process a node
      :do (dolist (adj (chip-spec-adj-qubits chip-spec cur))
            (unless (or (chip-spec-qubit-dead? chip-spec adj) (aref seen adj))
              (q-enq adj queue)
              (setf (aref seen adj) t)))
      :and :collect (cons cur level) :into distances
    :else
      ;; we have reached the end of the level
      :do (incf level)
      :and :do (q-enq nil queue)

    :finally (return (values distances seen))))

(defun chip-spec-live-qubit-cc (chip-spec)
  "Get a list of lists of live qubits that are in the same connected component on the chip."
  (loop
    :with n-qubits := (chip-spec-n-qubits chip-spec)
    :with seen := (make-array n-qubits :initial-element nil)

    :for qubit :below n-qubits
    :unless (or (chip-spec-qubit-dead? chip-spec qubit) (aref seen qubit))
      :collect (mapcar #'car (chip-spec-live-qubit-bfs chip-spec qubit seen))))

(defun instr-used-qubits-ccs (instrs)
  (prog-used-qubits-ccs
   (make-instance 'parsed-program :executable-code (coerce instrs 'vector))))

(defun prog-used-qubits-ccs (parsed-prog)
  "Return the connected components of qubits as used by the program."
  (let* ((n-qubits (qubits-needed parsed-prog))
         ;; This mapping maps a vertex to an index representing a connected
         ;; component.
         (connected-component-map (make-array n-qubits :initial-element -1)))
    (flet ((ensure-qubit-component (qubit)
             (let ((index (qubit-index qubit)))
               ;; Vertices are initially assigned to their own component.
               (when (minusp (aref connected-component-map index))
                 (setf (aref connected-component-map index) index))))
           (merge-qubit-components (qubit1 qubit2)
             (let ((component1 (aref connected-component-map (qubit-index qubit1)))
                   (component2 (aref connected-component-map (qubit-index qubit2))))
               (unless (= component1 component2)
                 (dotimes (index n-qubits)
                   (when (= (aref connected-component-map index) component2)
                     (setf (aref connected-component-map index) component1)))))))
      (loop :for inst :across (parsed-program-executable-code parsed-prog)
            :do (typecase inst
                  (measurement
                   (ensure-qubit-component (measurement-qubit inst)))
                  (application
                   ;; Merge the components of the arguments.
                   (destructuring-bind (first . rest)
                       (application-arguments inst)
                     (ensure-qubit-component first)
                     (dolist (qubit rest)
                       (ensure-qubit-component qubit)
                       (merge-qubit-components first qubit)))))))
    (let ((component-indices '()))
      (loop :for component-index :across connected-component-map :do
        (unless (minusp component-index)
          (pushnew component-index component-indices)))
      (loop :for component :in component-indices
            :collect (loop :for index :from 0 :below n-qubits
                           :when (= component (aref connected-component-map index))
                             :collect index)))))

(defparameter *rewiring-adjacency-weight-decay* 2.0
  "Rate of decay on the weight of instruction value for closeness.")

(defparameter *rewiring-distance-offset* 0.0
  "How much we should shift the distances before weighting. High values means small differences in distance have smaller effect.")

(defun compute-adjacency-weights (n-qubits order)
  "Given the order in which to expect qubits, compute the relative benefit of
being close to each of the n qubits."
  (loop
    :with weights-by-qubit := (make-array n-qubits :initial-element 0d0)
    :for adj :in order
    :for weight := 1d0 :then (/ weight *rewiring-adjacency-weight-decay*)
    :do (incf (aref weights-by-qubit adj) weight)
    :finally (return weights-by-qubit)))

(defun prog-rewiring-pragma (parsed-prog)
  "Finds a rewiring pragma in the parsed program. This pragma needs to occur
before any non-pragma instructions.

If no

    PRAGMA INITIAL_REWIRING \"...\"

is found, then return NIL."
  (loop :for inst :across (parsed-program-executable-code parsed-prog) :do
    (cond
      ((typep inst 'pragma)
       (when (typep inst 'pragma-initial-rewiring)
         (return-from prog-rewiring-pragma (pragma-rewiring-type inst))))
      (t
       (return-from prog-rewiring-pragma nil)))))

(defun %naively-applicable-p (instr chip-spec
                              &aux (qubit-indices (qubits-used instr)))
  "Return true if the given INSTR does not consume qubit arguments or if the qubit arguments correspond to a valid HARDWARE-OBJECT in CHIP-SPEC."
  (or (null qubit-indices)
      (a:when-let ((obj (lookup-hardware-object-by-qubits chip-spec qubit-indices)))
        (and (or (/= 2 (length qubit-indices))
                 (not (hardware-object-dead-p obj)))
             (or (/= 1 (length qubit-indices))
                 (not (chip-spec-qubit-dead? chip-spec (first qubit-indices))))))))

(defun prog-initial-rewiring-heuristic (parsed-prog chip-spec)
  "Return a resonable guess at the initial rewiring for PARSED-PROG that is compatible with CHIP-SPEC.

If PARSED-PROG contains an explicit PRAGMA INITIAL_REWIRING, respect it.
Otherwise, if every GATE-APPLICATION in PARSED-PROG can use a NAIVE rewiring, return ':NAIVE.
Otherwise, return *INITIAL-REWIRING-DEFAULT-TYPE*."
  (or (prog-rewiring-pragma parsed-prog)
      (and (every (a:rcurry #'%naively-applicable-p chip-spec)
                  (parsed-program-executable-code parsed-prog))
           ':naive)
      *initial-rewiring-default-type*))

;;; Note: This is a classic greedy allocation scheme, so it may not always be
;;; able to fit all the logical connected components into the given physical
;;; connected components when possible.
(defun greedy-prog-ccs-to-chip-ccs (chip-ccs prog-ccs)
  "Attempt to allocate the connected components of qubits as used in the program onto the chip connected components, and flame if such an allocation is not possible."
  (let ((chip-ccs (sort chip-ccs #'> :key #'length))
        (unallocated-prog-ccs (sort prog-ccs #'> :key #'length))
        (l2p-components (make-hash-table)))
    (dolist (unallocated-chip-cc chip-ccs)
      ;; Keep trying to fit the largest unallocated program connected
      ;; component into the current chip connected component.
      (let ((free (length unallocated-chip-cc)))
        (dolist (unallocated-prog-cc unallocated-prog-ccs)
          (let ((prog-cc-size (length unallocated-prog-cc)))
            (when (<= prog-cc-size free)
              (setf unallocated-prog-ccs (delete unallocated-prog-cc
                                                 unallocated-prog-ccs))
              (setf (gethash unallocated-prog-cc l2p-components)
                    unallocated-chip-cc)
              (decf free prog-cc-size))))))
    (when unallocated-prog-ccs
      (error "User program incompatible with chip: The program uses operations ~
    on qubits that cannot be logically mapped onto the chip topology. This set ~
    of qubits in the program cannot be assigned to qubits on the chip ~
    compatibly under a greedy connected component allocation scheme: ~a. The ~
    chip has the components ~a." prog-ccs chip-ccs))
    l2p-components))

(defun prog-initial-rewiring (parsed-prog chip-spec &key (type *initial-rewiring-default-type*))
  "Find an initial rewiring for a program, ensuring all used qubits in the program can fit on the connected components of the QPU compatibly."
  (let ((n-qubits (chip-spec-n-qubits chip-spec))
        (chip-connected-components (chip-spec-live-qubit-cc chip-spec))
        (prog-connected-components (prog-used-qubits-ccs parsed-prog)))
    (assert (<= (qubits-needed parsed-prog) n-qubits)
            ()
            "User program incompatible with chip: qubit index ~A used and ~A available."
            (qubits-needed parsed-prog) n-qubits)
    (case type
      (:naive
       ;; Check that every connected component of program qubits is contained
       ;; in a connected component on the chip.
       (unless (loop :for prog-connected-component in prog-connected-components
                     :always (loop :for chip-connected-component in chip-connected-components
                                     :thereis (subsetp prog-connected-component chip-connected-component)))
         (error "User program incompatible with chip: naive rewiring crosses chip component boundaries."))
       (make-rewiring n-qubits))
      (:partial
       (make-partial-rewiring n-qubits))
      (:random
       (generate-random-rewiring n-qubits))
      (:greedy
       ;; TODO: this assumes that the program is sequential
       (let ((rewiring (make-partial-rewiring n-qubits))
             (l2p-components (greedy-prog-ccs-to-chip-ccs chip-connected-components
                                                          prog-connected-components))
              ;; compute for each qubit pair (q1 q2) the benefit of putting q2 close to q1
              (l2l-multiplier (map 'vector
                                   (lambda (order) (compute-adjacency-weights n-qubits order))
                                   (prog-qubit-pair-order n-qubits parsed-prog)))

              ;; physical qubit -> logical qubit -> distance
              (p2l-distances (make-array n-qubits :initial-element nil)))
         (flet ((qubit-best-location (qubit prog-cc)
                  (let ((l-multiplier (aref l2l-multiplier qubit))
                        best
                        (best-cost most-positive-double-float))
                    (dolist (physical-target (gethash prog-cc l2p-components))
                      (let ((cost (loop :for (placed . distance) :in (aref p2l-distances physical-target)
                                        :sum (* (aref l-multiplier placed)
                                                (+ *rewiring-distance-offset* distance)))))
                        (unless (apply-rewiring-p2l rewiring physical-target)
                          (when (< cost best-cost)
                            (setf best physical-target
                                  best-cost cost)))))
                    best)))
           ;; assign all of the needed qubits
           (dolist (prog-cc prog-connected-components)
             (dolist (qubit prog-cc)
               (let ((location (qubit-best-location qubit prog-cc)))
                 ;; assign the qubit to the best location
                 (rewiring-assign rewiring qubit location)

                 ;; update the distances
                 (loop
                   :for (other-location . distance) :in (chip-spec-live-qubit-bfs chip-spec location)
                   :do (push (cons qubit distance) (aref p2l-distances other-location))))))
           rewiring)))
      (t
       (error "Unexpected rewiring type: ~A." type)))))

(defun prog-qubit-pair-order (n-qubits parsed-prog)
  "For each qubit, find a list of the other qubits it communicates with in order
of use."
  (loop
    :with per-qubit-ins := (make-array n-qubits :initial-element nil)
    :for inst :across (parsed-program-executable-code parsed-prog)
    :when (and (typep inst 'application)
               (= (length (application-arguments inst)) 2))
      :do (destructuring-bind (q1 q2) (application-arguments inst)
            (let ((q1 (qubit-index q1)) (q2 (qubit-index q2)))
              (push q2 (aref per-qubit-ins q1))
              (push q1 (aref per-qubit-ins q2))))
    :finally (return (map-into per-qubit-ins #'nreverse per-qubit-ins))))

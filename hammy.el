;;; hammy.el --- Programmable, interactive interval timers (e.g. for working and resting)  -*- lexical-binding: t; -*-

;; Copyright (C) 2022  Adam Porter

;; Author: Adam Porter <adam@alphapapa.net>
;; URL: https://github.com/alphapapa/hammy.el
;; Version: 0.1-pre
;; Package-Requires: ((emacs "28.1") (ts "0.2.2"))
;; Keywords: convenience

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This library provides programmable, interactive interval timers for
;; Emacs.  They can be used, e.g. to alternate between working and
;; resting periods, to remind yourself to stretch your legs, etc.
;; Timers, called "hammys," are easily defined by the user to behave
;; as desired, and they can be integrated into other programs by
;; calling Lisp functions in the hammys' definitions.

;;;; FAQ

;; Q: Why are timers called hammys?  Isn't that silly?

;; A: Probably.  But it also helps to distinguish them from Emacs's
;; timers, which are used in the implementation.  And besides, 🐹!

;;; Code:

;; TODO: Pausing.
;; TODO: Summarize logged interval times.

;;;; Requirements

(require 'cl-lib)
(require 'ring)

(require 'ts)

;;;; Structs

(cl-defstruct hammy
  (name "" :type 'string) (documentation "" :documentation "Documentation.")
  (elapsed nil :documentation "List of elapsed intervals.
Each element is a list of three elements: the interval, the time
it began, and the time it ended.")
  (cycles 0 :documentation "Number of times the timer has gone through a cycle of all intervals.")
  (intervals nil :documentation "List of defined intervals.")
  (interval nil :documentation "Current interval, if any.")
  (current-interval-start-time nil :documentation "Time at which the current interval started.")
  (current-duration)
  (last-duration nil :documentation "Length in seconds of last interval.")
  (timer nil :documentation "Emacs timer for this timer.")
  (etc nil :documentation "Alist which may be used to store any extra data.")
  (before nil :documentation "Function called before running timer.
Called with one argument, the hammy.")
  (after nil :documentation "Function called after timer has completed.
Called with one argument, the hammy.  Called when the hammy's
completion predicate returns non-nil.")
  (complete-p nil :documentation "Predicate that returns non-nil when hammy is complete.
Called with one argument, the hammy.  Called after each interval
is complete, before starting the next interval.")
  (overduep))

(cl-defstruct hammy-interval
  (name "" :type 'string)
  (documentation "" :documentation "Documentation.") ; !
  (face nil :documentation "Optional face in which to show the name of the interval.")
  (duration nil :documentation "Number of seconds or function that returns such.
If a function, it is given one argument, the timer it is being
run in.")
  (before nil :documentation "Function called before interval begins.
Called with one argument, the Hammy timer.")
  (after nil :documentation "Function called when interval ends.
Called with one argument, the Hammy timer.")
  (advance 'auto :documentation "How to advance to the next interval when this one ends.
If nil, do so automatically.  Otherwise, a list of functions to
call when the interval is ready to be advanced, and don't advance
until the user calls `hammy-next'."))

(define-error 'hammy-complete "Hammy is over!")

;;;; Macros

(defmacro hammy-define (name &rest args)
  "Define a new Hammy named NAME made with ARGS.
Returns the hammy, and adds hammy to `hammy-hammys'.  NAME is a
string.  ARGS are passed to `make-hammy', which see.  Within
ARGS, these functions are available to be called:

  `announce':"
  (declare (indent defun))
  ;; FIXME: Docstring.
  
  ;; In some ways, it might be preferable for this macro to expand to
  ;; the hammy struct, but then it wouldn't be forward-compatible if
  ;; the structure changes, so we just expand to the code that makes
  ;; the struct.

  ;; NOTE: If a user byte-compiles a config file containing a
  ;; `hammy-define' call, and the definition of this macro changes in
  ;; a later version, it will be a problem.  So it would be nice if
  ;; this were a function instead of a macro, but that would mean that
  ;; the user would have to quote the argument to prevent evaluation,
  ;; which would likely be confusing to many users.  So, for now, at
  ;; least, it will be a macro.
  `(cl-macrolet ((do (form)
                     `(lambda (_hammy)
                        ,form))
                 (listify (place)
                          `(unless (listp ,place)
                             (setf ,place (list ,place)))))
     ;; NOTE: Some of these functions are called at "hammy time" (I
     ;; know...), while others return lambdas to be called at hammy
     ;; time.
     (cl-labels ((announce (message)
                           (lambda (hammy)
                             (hammy-announce hammy message)))
                 (notify (message)
                         (lambda (hammy)
                           (hammy-notify hammy message)))
                 ;; (do (form)
                 ;;     `(lambda (hammy)
                 ;;        (ignore hammy)
                 ;;        ,form))
                 (duration (interval)
                           (timer-duration interval) )
                 (interval (&rest args)
                           (apply #'make-hammy-interval args))
                 (num-intervals (hammy)
                                (ring-length (hammy-intervals hammy)))
                 (elapsed (hammy)
                          (hammy-elapsed hammy))
                 (cycles (hammy)
                         (hammy-cycles hammy))
                 (climb (from to &key descend)
                        ;; FIXME: Make arguments optional.
                        ;; TODO: Step argument (e.g. increase/decrease by N seconds).
                        (lambda (hammy)
                          (let* ((apex (/ (duration to)
                                          (duration from)))
                                 (duration (if (< (cycles hammy) apex)
                                               ;; Spin up!
                                               (min (* (pcase (cycles hammy)
                                                         (0 1)
                                                         (cycles (1+ cycles)))
                                                       (duration from))
                                                    (duration to))
                                             ;; Spin down...
                                             (pcase-exhaustive descend
                                               (`nil (min (* (pcase (cycles hammy)
                                                               (0 1)
                                                               (height (1+ height)))
                                                             (duration from))
                                                          (duration to)))
                                               (`t (hammy-log hammy (format "Descending... (Cycles:%s  Apex:%s  From:%s  To:%s"
                                                                            (cycles hammy) apex from to))
                                                   (min (* (pcase (- (* 2 apex) (cycles hammy))
                                                             (0 1)
                                                             (height (1- height)))
                                                           (duration from))
                                                        (duration to)))))))
                            duration)))
                 (remind (delay fns)
                         (lambda (hammy)
                           (listify (hammy-after hammy))
                           (cl-pushnew #'cancel-reminder (hammy-after hammy))
                           (dolist (fn fns)
                             (funcall fn hammy))
                           (let ((delay-secs (duration delay)))
                             ;; TODO: Allow the duration to also be a function to return the reminder delay.
                             (setf (alist-get 'reminder (hammy-etc hammy))
                                   (run-with-timer delay-secs delay-secs
                                                   (lambda (hammy)
                                                     (dolist (fn fns)
                                                       (funcall fn hammy)))
                                                   hammy)))
                           ;; TODO: Might need to cancel and restart
                           ;; the reminder when a hammy is paused,
                           ;; too.
                           (listify (hammy-interval-after (hammy-interval hammy)))
                           (cl-pushnew #'cancel-reminder (hammy-interval-after (hammy-interval hammy)))))
                 (cancel-reminder (hammy)
                                  (when (alist-get 'reminder (hammy-etc hammy))
                                    (cancel-timer (alist-get 'reminder (hammy-etc hammy)))
                                    (setf (alist-get 'reminder (hammy-etc hammy)) nil))))
       (let* ((hammy (make-hammy :name ,name ,@args))
              (ring (make-ring (length (hammy-intervals hammy)))))
         (dolist (interval (hammy-intervals hammy))
           (ring-insert-at-beginning ring interval))
         (setf (hammy-intervals hammy) ring)
         (setf hammy-hammys (cl-delete ,name hammy-hammys :test #'equal :key #'hammy-name))
         (push hammy hammy-hammys)
         hammy))))

(defmacro hammy-run-place (place &rest args)
  `(cl-typecase ,place
     (function (funcall ,place ,@args))
     (null nil)
     (list (dolist (fn ,place)
             (funcall fn ,@args)))))

;;;; Variables

(defvar hammy-hammys nil
  "List of defined hammys.
Define a hammy with `hammy-define'.")

(defvar hammy-active nil
  "List of active hammys.")

;;;; Customization

(defgroup hammy nil
  "Programmable interval timers."
  :group 'convenience)

(defcustom hammy-log-buffer-name "*Hammy Log*"
  "Name of Hammy log buffer."
  :type 'string)

(defcustom hammy-start-hook '((lambda (hammy) (hammy-log hammy "Starting...")))
  "Functions run when a hammy is started.
Called with the hammy, and optionally a message."
  :type 'hook)

(defcustom hammy-complete-hook '((lambda (hammy) (hammy-log hammy "Completed.")))
  "Functions run when a hammy is completed.
That is, when the hammy completes its programmed cycles (not when
manually interrupted).  Called with the hammy, and optionally a
message."
  :type 'hook)

(defcustom hammy-interval-hook '((lambda (hammy &optional message) (hammy-log hammy message)))
  "Functions run when a hammy completes an interval.
Called with the hammy, and optionally a message."
  :type 'hook)

(defcustom hammy-cycle-hook '((lambda (hammy) (hammy-log hammy "Cycled.")))
  "Functions run when a hammy completes a cycle.
Called with the hammy, and optionally a message."
  :type 'hook)

;;;; Commands

(defun hammy-stop (hammy &optional quietly)
  "Stop HAMMY timer.
If QUIETLY, don't say so."
  (interactive
   (list (or (hammy-complete "Stop hammy: " hammy-active)
             (user-error "No active hammys"))))
  (pcase-let* (((cl-struct hammy (timer internal-timer)) hammy)
               ;; TODO: Logging, totals, etc.
               (message "Stopped."))
    (setf hammy-active (remove hammy hammy-active))
    (when internal-timer
      (cancel-timer internal-timer)
      (setf (hammy-timer hammy) nil)
      (hammy-log hammy message)
      (unless quietly
        (message message)))
    (hammy-reset hammy)
    hammy))

(defun hammy-reset (hammy)
  "Reset HAMMY timer.
If already running, restarts it."
  (interactive (list (hammy-complete "Reset hammy: " hammy-hammys)))
  (let ((runningp (hammy-timer hammy)))
    (when runningp
      (hammy-stop hammy 'quietly))
    (setf (hammy-cycles hammy) 0
          (hammy-elapsed hammy) nil
          (hammy-interval hammy) nil
          (hammy-current-interval-start-time hammy) nil
          (hammy-overduep hammy) nil)
    (when runningp
      (hammy-start hammy))
    hammy))

(defun hammy-toggle (hammy)
  "Toggle HAMMY timer.
If paused, resume it.  If running, pause it."
  (interactive (list (hammy-complete "Toggle hammy: " hammy-hammys)))
  (if (hammy-timer hammy)
      (let ((remaining-time (float-time (time-subtract (timer--time hammy) (current-time)))))
        (setf (alist-get 'remaining-time (hammy-etc hammy)) remaining-time)
        (hammy-stop hammy))
    (hammy-start hammy (alist-get 'remaining-time (hammy-etc hammy)))
    (setf (alist-get 'remaining-time (hammy-etc hammy)) nil))
  hammy)

;;;; Functions

(defun hammy-start (hammy &optional duration)
  "Start HAMMY and return it.
If DURATION, set its first interval to last that many seconds."
  (interactive (list (hammy-complete "Start hammy: " (cl-remove-if #'hammy-timer hammy-hammys))
                     current-prefix-arg))
  (unless (and (= 0 (hammy-cycles hammy))
               (null (hammy-elapsed hammy))
               (null (hammy-interval hammy)))
    (user-error "Hammy already started: %s" (hammy-format hammy)))
  (run-hook-with-args 'hammy-start-hook hammy)
  (hammy-run-place (hammy-before hammy) hammy)
  (hammy-next hammy duration :advance t)
  (push hammy hammy-active)
  hammy)

(cl-defun hammy-next (hammy &optional duration &key advance)
  "Advance to HAMMY's next interval."
  (interactive (list (hammy-complete "Advance hammy: " hammy-active) nil :advance t))
  (cl-labels ((advancep
               () (or (and (hammy-interval hammy)
                           (eq 'auto (hammy-interval-advance (hammy-interval hammy))))
                      advance)))
    (unless (and (= 0 (hammy-cycles hammy))
                 (null (hammy-elapsed hammy))
                 (null (hammy-interval hammy)))
      ;; Hammy already started, interval completed.
      (push (list (hammy-interval hammy) (hammy-current-interval-start-time hammy) (current-time)) (hammy-elapsed hammy))
      (run-hook-with-args 'hammy-interval-hook hammy
                          (format "Interval ended: %s"
                                  (hammy-interval-name (hammy-interval hammy))))
      (hammy-run-place (hammy-interval-after (hammy-interval hammy)) hammy)
      (when (and (advancep)
                 (equal (hammy-interval hammy)
                        (ring-ref (hammy-intervals hammy)
                                  (1- (ring-length (hammy-intervals hammy))))))
        ;; Cycle completed.
        (cl-incf (hammy-cycles hammy))
        (run-hook-with-args 'hammy-cycle-hook hammy)))
    (if (and (advancep)
             (hammy-complete-p hammy)
             (funcall (hammy-complete-p hammy) hammy))
        ;; Hammy complete.
        (progn
          (hammy-stop hammy 'quietly)
          (run-hook-with-args 'hammy-complete-hook hammy)
          (hammy-run-place (hammy-after hammy) hammy)
          (setf hammy-active (remove hammy hammy-active)))
      ;; Hammy not complete: start next interval.
      (pcase-let* (((cl-struct hammy interval) hammy)
                   (next-interval (if interval
                                      (ring-next (hammy-intervals hammy) interval)
                                    (ring-ref (hammy-intervals hammy) 0)))
                   (next-duration (or duration
                                      (cl-etypecase (hammy-interval-duration next-interval)
                                        (number (hammy-interval-duration next-interval))
                                        (function (condition-case _err
                                                      (funcall (hammy-interval-duration next-interval) hammy)
                                                    (hammy-complete
                                                     (run-hook-with-args 'hammy-complete-hook hammy)
                                                     (message "Hammy is over!  (%s)" (hammy-name hammy))
                                                     nil)))))))
        (if (not (advancep))
            ;; Interval requires manual advancing.
            (progn
              (hammy-log hammy "Waiting for user to advance...")
              (setf (hammy-overduep hammy) t)
              (hammy-run-place (hammy-interval-advance (hammy-interval hammy)) hammy))
          ;; Advancing.
          (hammy-log hammy (format "Elapsed: %s" (hammy-format-current-times hammy)))
          (setf (hammy-interval hammy) next-interval
                (hammy-current-interval-start-time hammy) (current-time)
                (hammy-current-duration hammy) next-duration
                (hammy-overduep hammy) nil)
          (when next-duration
            (hammy-run-place (hammy-interval-before next-interval) hammy)
            (run-hook-with-args 'hammy-interval-hook hammy
                                (format "Interval started: %s (%s)"
                                        (hammy-interval-name (hammy-interval hammy))
                                        (ts-human-format-duration (hammy-current-duration hammy) 'abbr)))
            (setf (hammy-timer hammy) (run-at-time next-duration nil #'hammy-next hammy)))))))
  hammy)

(defun hammy-format (hammy &optional message)
  "Return formatted status for HAMMY, optionally with MESSAGE."
  (let* ((interval (cond ((hammy-interval hammy)
                          (format "%s (%s)"
                                  (hammy-interval-name (hammy-interval hammy))
                                  (ts-human-format-duration (hammy-current-duration hammy) 'abbr)))
                         ((and (hammy-complete-p hammy)
                               (funcall (hammy-complete-p hammy) hammy))
                          "Completed.")
                         (t
                          "None")))
         (message (if message (format "  Message:%S" message) "")))
    (format "Hammy (%s): Interval:%s  Cycles:%s%s"
            (hammy-name hammy) 
            interval
            (hammy-cycles hammy)
            message)))

(defun hammy-log (hammy &optional message)
  "Log MESSAGE for HAMMY to log buffer."
  (let ((inhibit-read-only t))
    (with-current-buffer (hammy--log-buffer)
      (save-excursion
        (goto-char (point-max))
        (insert (format-time-string "%Y-%m-%d %H:%M:%S  ") (hammy-format hammy message) "\n")))))

(defun hammy-format-current-times (hammy)
  "Return current times for HAMMY formatted.
String includes elapsed time of the current interval and any
overrun time."
  (let* ((elapsed-secs (float-time
                        (time-subtract (current-time)
                                       (hammy-current-interval-start-time hammy))))
         (difference (float-time
                      (time-subtract (hammy-current-duration hammy) elapsed-secs))))
    (format "%s%s"
            (ts-human-format-duration elapsed-secs 'abbr)
            (if (< difference 0)
                (format " (+%s)" (abs difference))
              ""))))

(defun hammy--log-buffer ()
  "Return Hammy log buffer."
  (with-current-buffer (get-buffer-create hammy-log-buffer-name)
    (read-only-mode)
    (current-buffer)))

(defun hammy-view-log ()
  "Show Hammy log buffer."
  (interactive)
  (pop-to-buffer (hammy--log-buffer)))

(defun hammy-complete (prompt hammys)
  "Return one of HAMMYS selected with completion."
  (cl-labels ((describe (hammy)
                        (format "%s (%s)"
                                (hammy-name hammy)
                                (hammy-documentation hammy))))
    (pcase (length hammys)
      (0 nil)
      (_ (let* ((map (cl-loop for hammy in hammys
                              collect (cons (describe hammy) hammy)))
                (description (completing-read prompt map nil t)))
           (alist-get description map nil nil #'equal))))))

(defun hammy-announce (hammy message)
  (message "Hammy (%s): %s"
           (hammy-name hammy) message))

;;;; Mode

(defun hammy--mode-line-update (&rest _ignore)
  "Force updating of all mode lines when a hammy is active."
  (when hammy-active
    (force-mode-line-update 'all)))

(define-minor-mode hammy-mode
  "Show active hammy in the mode line."
  :global t
  :group 'hammy
  (let ((lighter '(hammy-mode (:eval (hammy-mode-lighter)))))
    (if hammy-mode
        (progn
          (when hammy-mode-update-mode-line-continuously
            ;; TODO: Only run this timer when a hammy is running.
            (setf hammy-mode-update-mode-line-timer (run-with-timer 1 1 #'hammy--mode-line-update)))
          (add-hook 'hammy-interval-hook #'hammy--mode-line-update)
          ;; Avoid adding the lighter multiple times if the mode is activated again.
          (cl-pushnew (list lighter) mode-line-misc-info :test #'equal))
      (when hammy-mode-update-mode-line-timer
        (cancel-timer hammy-mode-update-mode-line-timer)
        (setf hammy-mode-update-mode-line-timer nil))
      (remove-hook 'hammy-interval-hook #'hammy--mode-line-update)
      (setf mode-line-misc-info
            (delete lighter mode-line-misc-info)))))

(defcustom hammy-mode-always-show-lighter t
  "Show lighter even when no hammys are running."
  :type 'boolean)

(defcustom hammy-mode-lighter-prefix "🐹"
  "Show lighter even when no hammys are running."
  :type 'string)

(defcustom hammy-mode-lighter-overdue "!"
  "Shown when hammy is due to be manually advanced."
  :type 'string)

(defcustom hammy-mode-lighter-suffix-inactive "None"
  "Shown when no hammys are running."
  :type 'string)

(defface hammy-mode-lighter-prefix-inactive '((t (:inherit warning)))
  "Used when no hammy is active.")
(defface hammy-mode-lighter-prefix-active '((t (:inherit font-lock-type-face)))
  "Used when no hammy is active.")
(defface hammy-mode-lighter-overdue '((t (:inherit error)))
  "Used when no hammy is active.")

(defcustom hammy-mode-update-mode-line-continuously t
  "Update the mode line every second while a hammy is running."
  :type 'boolean)

(defvar hammy-mode-update-mode-line-timer nil
  "Timer used to update the mode line.")

(defun hammy-mode-lighter ()
  ;; NOTE: This actually only shows the first active hammy, but it
  ;; seems unlikely that users will use more than one
  ;; simultaneously.
  (let ((hammy (car (cl-remove-if-not #'hammy-timer hammy-hammys))))
    (if hammy
        (let ((remaining (abs
                          ;; We use the absolute value because
                          ;; `ts-human-format-duration' returns 0 for
                          ;; negative numbers.
                          (- (hammy-current-duration hammy)
                             (float-time (time-subtract (current-time)
                                                        (hammy-current-interval-start-time hammy)))))))
          (format "%s%s%s(%s:%s) "
                  (propertize hammy-mode-lighter-prefix
                              'face 'hammy-mode-lighter-prefix-active)
                  (if (hammy-overduep hammy)
                      (propertize hammy-mode-lighter-overdue
                                  'face 'hammy-mode-lighter-overdue)
                    ":")
                  (hammy-name hammy)
                  (propertize (hammy-interval-name (hammy-interval hammy))
                              'face (hammy-interval-face (hammy-interval hammy)))
                  (concat (if (hammy-overduep hammy)
                              ;; We use the negative sign when
                              ;; counting down to the end of an
                              ;; interval (i.e. "T-minus...") .
                              "+" "-")
                          (ts-human-format-duration remaining 'abbr))))
      ;; No active hammys.
      (when hammy-mode-always-show-lighter
        (concat (propertize hammy-mode-lighter-prefix
                            'face 'hammy-mode-lighter-prefix-inactive)
                (if hammy-mode-lighter-suffix-inactive
                    (concat ":" hammy-mode-lighter-suffix-inactive))
                " ")))))

;;;; Notifications

(require 'notifications)

(defun hammy-notify (hammy &optional message)
  (notifications-notify :title (format "Hammy (%s)"
                                       (hammy-name hammy))
                        :body (or message (hammy-format hammy))))

;;;; Hammys

;; Pre-defined for convenience.

(hammy-define "Flywheel"
  :documentation "Get your momentum going!"
  :intervals (list (interval :name "Rest"
                             :face 'font-lock-type-face
                             :duration (duration "5 minutes")
                             :before (list (announce "Rest time!")
                                           (notify "Rest time!"))
                             :advance (list (announce "Rest time is over!")
                                            (notify "Rest time is over!")))
                   (interval :name "Work"
                             :face 'font-lock-builtin-face
                             :duration (climb "5 minutes" "45 minutes"
                                              :descend t)
                             :before (list (announce "Work time!")
                                           (notify "Work time!"))
                             :advance (list (announce "Work time is over!")
                                            (notify "Work time is over!"))))
  :after (list (announce "Flywheel session complete!")
               (notify "Flywheel session complete!"))
  :complete-p (lambda (hammy)
                (and (> (hammy-cycles hammy) 1)
                     (hammy-interval hammy)
                     (equal "Work" (hammy-interval-name (hammy-interval hammy)))
                     (equal (duration "5 minutes") (hammy-current-duration hammy)))))

(hammy-define "Move"
  :documentation "Don't forget to stretch your legs!"
  :intervals (list (interval :name "💺"
                             :duration (duration "45 minutes")
                             :face 'font-lock-type-face
                             :before (list (announce "Whew!")
                                           (notify "Whew!"))
                             :advance (remind "10 minutes"
                                              (list (announce "Time to stretch your legs!")
                                                    (notify "Time to stretch your legs!"))))
                   (interval :name "🤸"
                             :duration (duration "5 minutes")
                             :face 'font-lock-builtin-face
                             :before (list (announce "Move it!")
                                           (notify "Move it!"))
                             :advance (list (announce "Time for a sit-down...")
                                            (notify "Time for a sit-down...")))))

;;;; Footer

(provide 'hammy)

;;; hammy.el ends here

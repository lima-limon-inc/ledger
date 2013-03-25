;;; ldg-schedule.el --- Helper code for use with the "ledger" command-line tool

;; Copyright (C) 2013 Craig Earls (enderw88 at gmail dot com)

;; This file is not part of GNU Emacs.

;; This is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.
;;
;; This is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
;; or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
;; License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:
;; 
;; This module provides for automatically adding transactions to a
;; ledger buffer on a periodic basis. Recurrence expressions are
;; inspired by Martin Fowler's "Recurring Events for Calendars",
;; martinfowler.com/apsupp/recurring.pdf

;; use (fset 'VARNAME (macro args)) to put the macro definition in the
;; function slot of the symbol VARNAME.  Then use VARNAME as the
;; function without have to use funcall.

(defgroup ledger-schedule nil
  "Support for automatically recommendation transactions."
  :group 'ledger)

(defcustom ledger-schedule-buffer-name "*Ledger Schedule*"
  "Name for the schedule buffer"
  :type 'string
  :group 'ledger-schedule)

(defcustom ledger-schedule-look-backward 7
  "Number of days to look back in time for transactions."
  :type 'integer
  :group 'ledger-schedule)

(defcustom ledger-schedule-look-forward 14
  "Number of days auto look forward to recommend transactions"
  :type 'integer
  :group 'ledger-schedule)

(defcustom ledger-schedule-file "~/FinanceData/ledger-schedule.ledger"
  "File to find scheduled transactions."
  :type 'file
  :group 'ledger-schedule)

(defsubst between (val low high)
  (and (>= val low) (<= val high)))

(defun ledger-schedule-days-in-month (month year)
  "Return number of days in the MONTH, MONTH is from 1 to 12.
If year is nil, assume it is not a leap year"
  (if (between month 1 12)
      (if (and year (date-leap-year-p year) (= 2 month))
	  29
	  (nth (1- month) '(31 28 31 30 31 30 31 31 30 31 30 31)))
      (error "Month out of range, MONTH=%S" month)))

;; Macros to handle date expressions
      
(defmacro ledger-schedule-constrain-day-in-month-macro (count day-of-week)
  "Return a form that evaluates DATE that returns true for the COUNT DAY-OF-WEEK.
For example, return true if date is the 3rd Thursday of the
month.  Negative COUNT starts from the end of the month. (EQ
COUNT 0) means EVERY day-of-week (eg. every Saturday)"
  (if (and (between count -6 6) (between day-of-week 0 6))
      (cond ((zerop count) ;; Return true if day-of-week matches
	     `(eq (nth 6 (decode-time date)) ,day-of-week))
	    ((> count 0) ;; Positive count
	     (let ((decoded (gensym)))
	       `(let ((,decoded (decode-time date)))
		   (if (and (eq (nth 6 ,decoded) ,day-of-week)
			    (between  (nth 3 ,decoded) 
				      ,(* (1- count) 7) 
				      ,(* count 7)))
		       t
		       nil))))
	    ((< count 0) 
	     (let ((days-in-month (gensym))
		   (decoded (gensym)))
	       `(let* ((,decoded (decode-time date))
		       (,days-in-month (ledger-schedule-days-in-month 
					(nth 4 ,decoded) 
					(nth 5 ,decoded))))
		  (if (and (eq (nth 6 ,decoded) ,day-of-week)
			   (between  (nth 3 ,decoded) 
				     (+ ,days-in-month ,(* count 7)) 
				     (+ ,days-in-month ,(* (1+ count) 7))))
		      t
		      nil))))
	    (t
	     (error "COUNT out of range, COUNT=%S" count)))
      (error "Invalid argument to ledger-schedule-day-in-month-macro %S %S" 
	     count 
	     day-of-week)))

(defmacro ledger-schedule-constrain-numerical-date-macro (year month day)
  "Return a function of date that is only true if all constraints are met.
A nil constraint matches any input, a numerical entry must match that field 
of date."
  ;; Do bounds checking to make sure the incoming date constraint is sane
  (if 
   (if (eval month) ;; if we have a month
       (and (between (eval month) 1 12) ;; make sure it is between 1
					;; and twelve and the number
					;; of days are ok
	    (between (eval day) 1 (ledger-schedule-days-in-month (eval month) (eval year))))
       (between (eval day) 1 31))  ;; no month specified, assume 31 days.
   `'(and ,(if (eval year)  
		`(if (eq (nth 5 (decode-time date)) ,(eval year)) t)
		`t)
	   ,(if (eval month)
		`(if (eq (nth 4 (decode-time date)) ,(eval month)) t)
		`t)
	   ,(if (eval day)
		`(if (eq (nth 3 (decode-time date)) ,(eval day)) t)))
   (error "ledger-schedule-constraint-numerical-date-macro: date out of range %S %S %S" (eval year) (eval month) (eval day))))



(defmacro ledger-schedule-constrain-every-count-day-macro (day-of-week skip start-date)
  "Return a form that is true for every DAY skipping SKIP, starting on START.
For example every second Friday, regardless of month."
  (let ((start-day (nth 6 (decode-time (eval start-date)))))
     (if (eq start-day day-of-week)  ;; good, can proceed
	`(if (zerop (mod (- (time-to-days date) ,(time-to-days (eval start-date))) ,(* skip 7)))
	     t
	     nil)
	(error "START-DATE day of week doesn't match DAY-OF-WEEK"))))

(defmacro ledger-schedule-constrain-date-range-macro (month1 day1 month2 day2)
  "Return a form of DATE that is true if DATE falls between MONTH1 DAY1 and MONTH2 DAY2."
  (let ((decoded (gensym))
	(target-month (gensym))
	(target-day (gensym)))
    `(let* ((,decoded (decode-time date))
	    (,target-month (nth 4 decoded))
	    (,target-day (nth 3 decoded)))
       (and (and (> ,target-month ,month1)
		 (< ,target-month ,month2))
	    (and (> ,target-day ,day1)
		 (< ,target-day ,day2))))))


(defun ledger-schedule-is-holiday (date)
  "Return true if DATE is a holiday.")

(defun ledger-schedule-scan-transactions (schedule-file)
  "Scans AUTO_FILE and returns a list of transactions with date predicates.
The car of each item is a fuction of date that returns true if
the transaction should be logged for that day."
  (interactive "fFile name: ")
  (let ((xact-list (list)))
    (with-current-buffer
	(find-file-noselect schedule-file)
      (goto-char (point-min))
      (while (re-search-forward "^\\[\\(.*\\)\\] " nil t)
	(let ((date-descriptor "")
	      (transaction nil)
	      (xact-start (match-end 0)))
	  (setq date-descriptors 
		(ledger-schedule-read-descriptor-tree
		 (buffer-substring-no-properties 
		  (match-beginning 0) 
		  (match-end 0))))
	  (forward-paragraph)
	  (setq transaction (list date-descriptors
				  (buffer-substring-no-properties
				   xact-start
				   (point))))
	  (setq xact-list (cons transaction xact-list))))
    xact-list)))
	  
(defun ledger-schedule-replace-brackets ()
    "Replace all brackets with parens"
    (goto-char (point-min))
    (while (search-forward "]" nil t)
      (replace-match ")" nil t))
    (goto-char (point-min))
    (while (search-forward "[" nil t)
      (replace-match "(" nil t)))

(defun ledger-schedule-read-descriptor-tree (descriptor-string)
  "Take a date descriptor string and return a function that
returns true if the date meets the requirements"
  (with-temp-buffer
    ;; copy the descriptor string into a temp buffer for manipulation
    (let (pos)
      ;; Replace brackets with parens
      (insert descriptor-string)
      (ledger-schedule-replace-brackets)
      
      (goto-char (point-max))
      ;; double quote all the descriptors for string processing later
      (while (re-search-backward 
	      (concat "\\(20[0-9][0-9]\\|[\*]\\)[/\\-]"  ;; Year slot
		      "\\([\*EO]\\|[01][0-9]\\)[/\\-]" ;; Month slot
		      "\\([\*]\\|\\([0-3][0-9]\\)\\|"
		      "\\([0-5]"
		      "\\(\\(Su\\)\\|"
		      "\\(Mo\\)\\|" 
		      "\\(Tu\\)\\|"
		      "\\(We\\)\\|"
		      "\\(Th\\)\\|"
		      "\\(Fr\\)\\|"
		      "\\(Sa\\)\\)\\)\\)") nil t) ;; Day slot
	(goto-char 
	 (match-end 0))
	(insert ?\")
	(goto-char (match-beginning 0))
	(insert "\"" )))
    
    ;; read the descriptor string into a lisp object the transform the
    ;; string descriptor into useable things
    (ledger-transform-auto-tree 
     (read (buffer-substring-no-properties (point-min) (point-max))))))

(defun ledger-transform-auto-tree (tree)
"Takes a lisp list of date descriptor strings, TREE, and returns a string with a lambda function of date."
;; use funcall to use the lambda function spit out here
  (if (consp tree)
      (let (result)
	(while (consp tree)
	  (let ((newcar (car tree)))
	    (if (consp newcar)
		(setq newcar (ledger-transform-auto-tree (car tree))))
	    (if (consp newcar) 
		(push newcar result)
		(push (ledger-schedule-parse-date-descriptor newcar) result)) )
	  (setq tree (cdr tree)))

	;; tie up all the clauses in a big or and lambda
	`(lambda (date) 
	   ,(nconc (list 'or) (nreverse result) tree)))))

(defun ledger-schedule-split-constraints (descriptor-string)
  "Return a list with the year, month and day fields split"
  (let ((fields (split-string descriptor-string "[/\\-]" t))
	constrain-year constrain-month constrain-day)
    (if (string= (car fields) "*")
	(setq constrain-year nil)
	(setq constrain-year (car fields)))
    (if (string= (cadr fields) "*")
	(setq constrain-month nil)
	(setq constrain-month (cadr fields)))
    (if (string= (nth 2 fields) "*")
	(setq constrain-day nil)
	(setq constrain-day (nth 2 fields)))
    (list constrain-year constrain-month constrain-day)))

(defun ledger-string-to-number-or-nil (str)
  (if str
      (string-to-number str)
      nil))

(defun ledger-schedule-compile-constraints (constraint-list)
  (let ((year-constraint (ledger-string-to-number-or-nil (nth 0 constraint-list)))
	(month-constraint (ledger-string-to-number-or-nil (nth 1 constraint-list)))
	(day-constraint (ledger-string-to-number-or-nil (nth 2 constraint-list))))
    (ledger-schedule-constrain-numerical-date-macro 
     year-constraint
     month-constraint
     day-constraint)))

(defun ledger-schedule-parse-date-descriptor (descriptor)
  "Parse the date descriptor, return the evaluator"
  (ledger-schedule-compile-constraints 
   (ledger-schedule-split-constraints descriptor)))


(defun ledger-schedule-list-upcoming-xacts (candidate-items early horizon)
  "Search CANDIDATE-ITEMS for xacts that occur within the period today - EARLY  to today + HORIZON"
  (let ((start-date (time-subtract (current-time) (days-to-time early)))
	test-date items)
    (loop for day from 0 to (+ early horizon) by 1 do
	 (setq test-date (time-add start-date (days-to-time day)))
	 (dolist (candidate candidate-items items)
	   (if (funcall (car candidate) test-date)
	       (setq items (append items (list (list test-date (cadr candidate))))))))
    items))

(defun ledger-schedule-already-entered (candidate buffer)
  (let ((target-date (format-time-string date-format (car candidate)))
	     (target-payee (cadr candidate)))
    nil))

(defun ledger-schedule-create-auto-buffer (candidate-items early horizon ledger-buf)
  "Format CANDIDATE-ITEMS for display."
  (let ((candidates (ledger-schedule-list-upcoming-xacts candidate-items early horizon))
	(schedule-buf (get-buffer-create ledger-schedule-buffer-name))
	(date-format (cdr (assoc "date-format" ledger-environment-alist))))
    (with-current-buffer schedule-buf
      (erase-buffer)
     (dolist (candidate candidates)
       (if (not (ledger-schedule-already-entered candidate ledger-buf))
	   (insert (format-time-string date-format (car candidate) ) " " (cadr candidate) "\n"))))))


;;
;;  Test harnesses for use in ielm
;;
(defvar auto-items)

(defun ledger-schedule-test-setup ()
  (setq auto-items 
	(ledger-schedule-scan-transactions ledger-schedule-file)))


(defun ledger-schedule-test-predict ()
  (let ((today (current-time))
	test-date items)
    
    (loop for day from 0 to ledger-schedule-look-forward by 1 do
	 (setq test-date (time-add today (days-to-time day)))
	 ;;(message "date: %S" (decode-time test-date))
	 (dolist (item auto-items items)
	   (if (funcall (car item) test-date)
	       (setq items (append items (list (decode-time test-date) (cdr item)))))))
    items))

(provide 'ldg-schedule)

;;; ldg-schedule.el ends here

;;; ledger.el --- Helper code for use with the "ledger" command-line tool

;; Copyright (C) 2004 John Wiegley (johnw AT gnu DOT org)

;; Emacs Lisp Archive Entry
;; Filename: ledger.el
;; Version: 1.2
;; Date: Thu 02-Apr-2004
;; Keywords: data
;; Author: John Wiegley (johnw AT gnu DOT org)
;; Maintainer: John Wiegley (johnw AT gnu DOT org)
;; Description: Helper code for using my "ledger" command-line tool
;; URL: http://www.newartisans.com/johnw/emacs.html
;; Compatibility: Emacs21

;; This file is not part of GNU Emacs.

;; This is free software; you can redistribute it and/or modify it under
;; the terms of the GNU General Public License as published by the Free
;; Software Foundation; either version 2, or (at your option) any later
;; version.
;;
;; This is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
;; for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330, Boston,
;; MA 02111-1307, USA.

;;; Commentary:

;; To use this module: Load this file, open a ledger data file, and
;; type M-x ledger-mode.  Once this is done, you can type:
;;
;;   C-c C-a  add a new entry, based on previous entries
;;   C-c C-y  set default year for entry mode
;;   C-c C-m  set default month for entry mode
;;   C-c C-r  reconcile uncleared entries related to an account
;;
;; In the reconcile buffer, use SPACE to toggle the cleared status of
;; a transaction, C-x C-s to save changes (to the ledger file as
;; well), or C-c C-r to attempt an auto-reconcilation based on the
;; statement's ending date and balance.

(defvar ledger-version "1.2"
  "The version of ledger.el currently loaded")

(defgroup ledger nil
  "Interface to the Ledger command-line accounting program."
  :group 'data)

(defcustom ledger-binary-path (executable-find "ledger")
  "Path to the ledger executable."
  :type 'file
  :group 'ledger)

(defvar bold 'bold)
(defvar ledger-font-lock-keywords
  '(("^[0-9./]+\\s-+\\(?:([^)]+)\\s-+\\)?\\([^*].+\\)" 1 bold)
    ("^\\s-+.+?\\(  \\|\t\\|\\s-+$\\)" . font-lock-keyword-face))
  "Default expressions to highlight in Ledger mode.")

(defsubst ledger-current-year ()
  (format-time-string "%Y"))
(defsubst ledger-current-month ()
  (format-time-string "%m"))

(defvar ledger-year (ledger-current-year)
  "Start a ledger session with the current year, but make it
customizable to ease retro-entry.")
(defvar ledger-month (ledger-current-month)
  "Start a ledger session with the current month, but make it
customizable to ease retro-entry.")

(defun ledger-iterate-entries (callback)
  (goto-char (point-min))
  (let* ((now (current-time))
	 (current-year (nth 5 (decode-time now))))
    (while (not (eobp))
      (when (looking-at
	     (concat "\\(Y\\s-+\\([0-9]+\\)\\|"
		     "\\([0-9]\\{4\\}+\\)?[./]?"
		     "\\([0-9]+\\)[./]\\([0-9]+\\)\\s-+"
		     "\\(\\*\\s-+\\)?\\(.+\\)\\)"))
	(let ((found (match-string 2)))
	  (if found
	      (setq current-year (string-to-number found))
	    (let ((start (match-beginning 0))
		  (year (match-string 3))
		  (month (string-to-number (match-string 4)))
		  (day (string-to-number (match-string 5)))
		  (mark (match-string 6))
		  (desc (match-string 7)))
	      (if (and year (> (length year) 0))
		  (setq year (string-to-number year)))
	      (funcall callback start
		       (encode-time 0 0 0 day month
				    (or year current-year))
		       mark desc)))))
      (forward-line))))

(defun ledger-time-less-p (t1 t2)
  "Say whether time value T1 is less than time value T2."
  (or (< (car t1) (car t2))
      (and (= (car t1) (car t2))
	   (< (nth 1 t1) (nth 1 t2)))))

(defun ledger-time-subtract (t1 t2)
  "Subtract two time values.
Return the difference in the format of a time value."
  (let ((borrow (< (cadr t1) (cadr t2))))
    (list (- (car t1) (car t2) (if borrow 1 0))
	  (- (+ (if borrow 65536 0) (cadr t1)) (cadr t2)))))

(defun ledger-find-slot (moment)
  (catch 'found
    (ledger-iterate-entries
     (function
      (lambda (start date mark desc)
	(if (ledger-time-less-p moment date)
	    (throw 'found t)))))))

(defun ledger-add-entry (entry-text)
  (interactive
   (list
    (read-string "Entry: " (concat ledger-year "/" ledger-month "/"))))
  (let* ((date (car (split-string entry-text)))
	 (insert-year t)
	 (ledger-buf (current-buffer))
	 exit-code)
    (if (string-match "\\([0-9]+\\)/\\([0-9]+\\)/\\([0-9]+\\)" date)
	(setq date (encode-time 0 0 0 (string-to-int (match-string 3 date))
				(string-to-int (match-string 2 date))
				(string-to-int (match-string 1 date)))))
    (ledger-find-slot date)
    (save-excursion
      (if (re-search-backward "^Y " nil t)
	  (setq insert-year nil)))
    (save-excursion
      (insert
       (with-temp-buffer
	 (setq exit-code
	       (ledger-run-ledger
		ledger-buf "entry"
		(with-temp-buffer
		  (insert entry-text)
		  (goto-char (point-min))
		  (while (re-search-forward "\\([&$]\\)" nil t)
		    (replace-match "\\\\\\1"))
		  (buffer-string))))
	 (if (= 0 exit-code)
	     (if insert-year
		 (buffer-substring 2 (point-max))
	       (buffer-substring 7 (point-max)))
	   (concat (if insert-year entry-text
		     (substring entry-text 6)) "\n"))) "\n"))))

(defun ledger-toggle-current ()
  (interactive)
  (let (clear)
    (save-excursion
      (when (or (looking-at "^[0-9]")
		(re-search-backward "^[0-9]" nil t))
	(skip-chars-forward "0-9./")
	(delete-horizontal-space)
	(if (equal ?\* (char-after))
	    (delete-char 1)
	  (insert " * ")
	  (setq clear t))))
    clear))

(defvar ledger-mode-abbrev-table)

(define-derived-mode ledger-mode text-mode "Ledger"
  "A mode for editing ledger data files."
  (set (make-local-variable 'comment-start) ";")
  (set (make-local-variable 'comment-end) "")
  (set (make-local-variable 'indent-tabs-mode) nil)
  (if (boundp 'font-lock-defaults)
      (set (make-local-variable 'font-lock-defaults)
	   '(ledger-font-lock-keywords nil t)))
  (let ((map (current-local-map)))
    (define-key map [(control ?c) (control ?a)] 'ledger-add-entry)
    (define-key map [(control ?c) (control ?y)] 'ledger-set-year)
    (define-key map [(control ?c) (control ?m)] 'ledger-set-month)
    (define-key map [(control ?c) (control ?c)] 'ledger-toggle-current)
    (define-key map [(control ?c) (control ?r)] 'ledger-reconcile)))

;; Reconcile mode

(defvar ledger-buf nil)
(defvar ledger-acct nil)

(defun ledger-display-balance ()
  (let ((buffer ledger-buf)
	(account ledger-acct))
    (with-temp-buffer
      (let ((exit-code (ledger-run-ledger buffer "-C" "balance" account)))
	(if (/= 0 exit-code)
	    (message "Error determining cleared balance")
	  (goto-char (point-min))
	  (delete-horizontal-space)
	  (skip-syntax-forward "^ ")
	  (message "Cleared balance = %s"
		   (buffer-substring-no-properties (point-min) (point))))))))

(defun ledger-reconcile-toggle ()
  (interactive)
  (let ((where (get-text-property (point) 'where))
	(account ledger-acct)
	(inhibit-read-only t)
	cleared)
    (with-current-buffer ledger-buf
      (goto-char where)
      (setq cleared (ledger-toggle-current)))
    (if cleared
	(add-text-properties (line-beginning-position)
			     (line-end-position)
			     (list 'face 'bold))
      (remove-text-properties (line-beginning-position)
			      (line-end-position)
			      (list 'face)))
    (forward-line)))

(defun ledger-auto-reconcile (balance date)
  (interactive "sReconcile to balance: \nsStatement date: ")
  (let ((buffer ledger-buf)
	(account ledger-acct) cleared)
    ;; attempt to auto-reconcile in the background
    (with-temp-buffer
      (let ((exit-code
	     (ledger-run-ledger
	      buffer "--format" "\"%B\\n\"" "--reconcile"
	      (with-temp-buffer
		(insert balance)
		(goto-char (point-min))
		(while (re-search-forward "\\([&$]\\)" nil t)
		  (replace-match "\\\\\\1"))
		(buffer-string))
	      "--reconcile-date" date "register" account)))
	(when (= 0 exit-code)
	  (goto-char (point-min))
	  (unless (looking-at "[0-9]")
	    (error (buffer-string)))
	  (while (not (eobp))
	    (setq cleared
		  (cons (1+ (read (current-buffer))) cleared))
	    (forward-line)))))
    (goto-char (point-min))
    (with-current-buffer ledger-buf
      (setq cleared (mapcar 'copy-marker (nreverse cleared))))
    (let ((inhibit-redisplay t))
      (dolist (pos cleared)
	(while (and (not (eobp))
		    (/= pos (get-text-property (point) 'where)))
	  (forward-line))
	(unless (eobp)
	  (ledger-reconcile-toggle))))
    (goto-char (point-min))))

(defun ledger-reconcile-save ()
  (interactive)
  (with-current-buffer ledger-buf
    (write-region (point-min) (point-max) (buffer-file-name) nil 1)
    (set-buffer-modified-p nil))
  (set-buffer-modified-p nil)
  (ledger-display-balance))

(defun ledger-reconcile (account)
  (interactive "sAccount to reconcile: ")
  (let* ((buf (current-buffer))
	 (items
	  (with-temp-buffer
	    (let ((exit-code
		   (ledger-run-ledger buf "--reconcilable" "emacs" account)))
	      (when (= 0 exit-code)
		(goto-char (point-min))
		(unless (looking-at "(")
		  (error (buffer-string)))
		(read (current-buffer)))))))
    (with-current-buffer
	(pop-to-buffer (generate-new-buffer "*Reconcile*"))
      (ledger-reconcile-mode)
      (set (make-local-variable 'ledger-buf) buf)
      (set (make-local-variable 'ledger-acct) account)
      (dolist (item items)
	(dolist (xact (nthcdr 5 item))
	  (let ((beg (point)))
	    (insert (format "%s %-30s %-25s %15s\n"
			    (format-time-string "%m/%d" (nth 2 item))
			    (nth 4 item) (nth 0 xact) (nth 1 xact)))
	    (if (nth 1 item)
		(set-text-properties beg (1- (point))
				     (list 'face 'bold
					   'where (nth 0 item)))
	      (set-text-properties beg (1- (point))
				   (list 'where (nth 0 item)))))))
      (goto-char (point-min))
      (set-buffer-modified-p nil)
      (toggle-read-only t))))

(defvar ledger-reconcile-mode-abbrev-table)

(define-derived-mode ledger-reconcile-mode text-mode "Reconcile"
  "A mode for reconciling ledger entries."
  (let ((map (make-sparse-keymap)))
    (define-key map [(control ?c) (control ?r)] 'ledger-auto-reconcile)
    (define-key map [(control ?x) (control ?s)] 'ledger-reconcile-save)
    (define-key map [? ] 'ledger-reconcile-toggle)
    (define-key map [?q]
      (function
       (lambda ()
	 (interactive)
	 (kill-buffer (current-buffer)))))
    (use-local-map map)))

;; A sample function for $ users

(defun ledger-align-dollars (&optional column)
  (interactive "p")
  (if (= column 1)
      (setq column 48))
  (while (search-forward "$" nil t)
    (backward-char)
    (let ((col (current-column))
	  (beg (point))
	  target-col len)
      (skip-chars-forward "-$0-9,.")
      (setq len (- (point) beg))
      (setq target-col (- column len))
      (if (< col target-col)
	  (progn
	    (goto-char beg)
	    (insert (make-string (- target-col col) ? )))
	(move-to-column target-col)
	(if (looking-back "  ")
	    (delete-char (- col target-col))
	  (skip-chars-forward "^ \t")
	  (delete-horizontal-space)
	  (insert "  ")))
      (forward-line))))

;; General helper functions

(defun ledger-run-ledger (buffer &rest args)
  "run ledger with supplied arguments"
  (let ((buf (current-buffer)))
    (with-current-buffer buffer
      (apply #'call-process-region
	     (append (list (point-min) (point-max)
			   ledger-binary-path nil buf nil "-f" "-")
		     args)))))

(defun ledger-set-year (newyear)
  "Set ledger's idea of the current year to the prefix argument."
  (interactive "p")
  (if (= newyear 1)
      (setq ledger-year (read-string "Year: " (ledger-current-year)))
    (setq ledger-year (number-to-string newyear))))

(defun ledger-set-month (newmonth)
  "Set ledger's idea of the current month to the prefix argument."
  (interactive "p")
  (if (= newmonth 1)
      (setq ledger-month (read-string "Month: " (ledger-current-month)))
    (setq ledger-month (format "%02d" newmonth))))

(provide 'ledger)

;;; ledger.el ends here

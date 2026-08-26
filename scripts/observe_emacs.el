;;; observe_emacs.el --- Black-box partial completion observations -*- lexical-binding: t; -*-

(setq completion-styles '(partial-completion))

(defun partial-completion-observe--plain (query table)
  "Return unpropertized completions for QUERY in TABLE."
  (let ((rest (completion-all-completions query table nil (length query)))
        result)
    (while (consp rest)
      (push (substring-no-properties (car rest)) result)
      (setq rest (cdr rest)))
    (nreverse result)))

(defun partial-completion-observe--sorted-file (query)
  "Return the minibuffer cycling order for file completion of QUERY."
  (with-temp-buffer
    (insert query)
    (goto-char (point-max))
    (setq-local minibuffer-completion-table #'completion-file-name-table
                minibuffer-completion-predicate nil
                completion-all-sorted-completions nil)
    (let* ((all (completion-all-sorted-completions (point-min) (point-max)))
           (tail (last all)))
      (when tail
        (setcdr tail nil))
      (mapcar #'substring-no-properties all))))

(let ((candidates '("debug-list" "debug-long-list" "debug-longer-list"
                    "delete-line" "describe-link" "delta"
                    "TelescopeFindFiles" "telescope-find-files")))
  (dolist (query '("de-li" "de--li" "de---li" "d-l" "dl"
                    "t-f-f" "tff" "DE-LI" "de*li"))
    (prin1 (list 'list query
                 (partial-completion-observe--plain query candidates)))
    (terpri))
  (let ((completion-ignore-case t))
    (prin1 (list 'list-case-fold "DE-LI"
                 (partial-completion-observe--plain "DE-LI" candidates)))
    (terpri)))

(let* ((root (make-temp-file "partial-completion-emacs-" t))
       (default-directory (file-name-as-directory root))
       (completion-ignore-case t))
  (unwind-protect
      (progn
        (dolist (path '("Desktop/Library" "Developer/lib" "docs/lint"
                        "Desktop/Local/Library" "foo/bar" "fizz/barn"))
          (make-directory (expand-file-name path root) t))
        (dolist (query '("de/li" "d/l" "de/l" "de/lo/li" "de//li"
                         "./de/li" "f*/ba" "fo*/b*" "foo/./ba"
                         "foo/../fo/ba" "foo/." "foo/.."))
          (prin1
           (list 'file query
                 (partial-completion-observe--plain
                  query #'completion-file-name-table)))
          (terpri)))
    (delete-directory root t)))

(let* ((root (make-temp-file "partial-completion-emacs-order-" t))
       (default-directory (file-name-as-directory root))
       (completion-ignore-case t))
  (unwind-protect
      (progn
        (dolist (path '("d/é" "d/aa"))
          (make-directory (expand-file-name path root) t))
        (prin1 (list 'file-cycle-order "d/"
                     (partial-completion-observe--sorted-file "d/")))
        (terpri))
    (delete-directory root t)))

(let* ((root (make-temp-file "partial-completion-emacs-mixed-order-" t))
       (default-directory (file-name-as-directory root))
       (completion-ignore-case t))
  (unwind-protect
      (progn
        (dolist (path '("Desktop/a" "docs/long-child" "dotfiles/b"))
          (make-directory (expand-file-name path root) t))
        (prin1 (list 'file-cycle-mixed-order "d/"
                     (partial-completion-observe--sorted-file "d/")))
        (terpri))
    (delete-directory root t)))

;;; observe_emacs.el ends here

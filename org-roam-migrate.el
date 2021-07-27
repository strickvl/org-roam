;;; org-roam-migrate.el --- Migration utilities from v1 to v2 -*- coding: utf-8; lexical-binding: t; -*-

;; Copyright © 2020-2021 Jethro Kuan <jethrokuan95@gmail.com>

;; Author: Jethro Kuan <jethrokuan95@gmail.com>
;; URL: https://github.com/org-roam/org-roam
;; Keywords: org-mode, roam, convenience
;; Version: 2.0.0
;; Package-Requires: ((emacs "26.1") (dash "2.13") (f "0.17.2") (org "9.4") (emacsql "3.0.0") (emacsql-sqlite "1.0.0") (magit-section "2.90.1"))

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:
;;
;;  To ease transition from v1 to v2, we provide various migration utilities.
;;  This library helps convert v1 notes to v2, and informs the user.
;;
;;; Code:
;;;; Dependencies
;;;;
;;; v1 breaking warning
(require 'org-roam-db)

(defvar org-roam-v2-ack nil)

(unless org-roam-v2-ack
  (lwarn 'org-roam :error "
------------------------------------
WARNING: You're now on Org-roam v2!
------------------------------------

You may have arrived here from a package upgrade. Please read the
wiki entry at
https://github.com/org-roam/org-roam/wiki/Hitchhiker's-Rough-Guide-to-Org-roam-V2
for an overview of the major changes.

Notes taken in v1 are incompatible with v2, but you can upgrade
them to the v2 format via a simple command. To migrate your
notes, first make sure you're on at least Org 9.4 (check with
C-h v org-version) and set your org-roam-directory to your notes:

(setq org-roam-directory \"path/to/org/files\")

then, run:

  M-x org-roam-migrate-wizard

If you wish to stay on v1, v1 is unfortunately not distributed on
MELPA. See org-roam/org-roam-v1 on GitHub on how to install v1.

If you've gone through the migration steps (if necessary), and
know what you're doing set `org-roam-v2-ack' to `t' to disable
this warning. You can do so by adding:

(setq org-roam-v2-ack t)

To your init file.

"))

;;;###autoload (autoload 'org-roam-migrate-wizard "org-roam" nil t)
(defun org-roam-migrate-wizard ()
  "Migrate all notes from to be compatible with Org-roam v2.
1. Convert all notes from v1 format to v2.
2. Rebuild the cache.
3. Replace all file links with ID links."
  (interactive)
  (when (yes-or-no-p "Org-roam will now convert all your notes from v1 to v2.
This will take a while. Are you sure you want to do this?")
    ;; Back up notes
    (let ((backup-dir (expand-file-name "org-roam.bak"
                                        (file-name-directory (directory-file-name org-roam-directory)))))
      (message "Backing up files to %s" backup-dir)
      (copy-directory org-roam-directory backup-dir))

    ;; Upgrade database to v2
    (org-roam-db-sync 'force)

    ;; Convert v1 to v2
    (dolist (f (org-roam--list-all-files))
      (org-roam-with-file f nil
        (org-roam-migrate-v1-to-v2)))

    ;; Rebuild cache
    (org-roam-db-sync 'force)

    ;;Replace all file links with ID links
    (dolist (f (org-roam--list-all-files))
      (org-roam-with-file f nil
        (org-roam-migrate-replace-file-links-with-id)
        (save-buffer)))))

(defun org-roam-migrate-v1-to-v2 ()
  "Convert the current buffer to v2 format."
  ;; Create file level ID
  (org-with-point-at 1
    (org-id-get-create))
  ;; Replace roam_key into properties drawer roam_ref
  (when-let* ((refs (mapcan #'split-string-and-unquote
                            (cdar (org-collect-keywords '("roam_key"))))))
    (let ((case-fold-search t))
      (org-with-point-at 1
        (dolist (ref refs)
          (org-roam-ref-add ref))
        (while (re-search-forward "^#\\+roam_key:" (point-max) t)
          (beginning-of-line)
          (kill-line 1)))))

  ;; Replace roam_alias into properties drawer roam_aliases
  (when-let* ((aliases (mapcan #'split-string-and-unquote
                               (cdar (org-collect-keywords '("roam_alias"))))))
    (dolist (alias aliases)
      (org-roam-alias-add alias)))
  (let ((case-fold-search t))
    (org-with-point-at 1
      (while (re-search-forward "^#\\+roam_alias:" (point-max) t)
        (beginning-of-line)
        (kill-line 1))))

  ;; Replace #+roam_tags into #+filetags
  (org-with-point-at 1
    (let* ((roam-tags (org-roam-migrate-get-prop-list "ROAM_TAGS"))
           (file-tags (cl-mapcan (lambda (value)
                                   (cl-mapcan
                                    (lambda (k) (org-split-string k ":"))
                                    (split-string value)))
                                 (org-roam-migrate-get-prop-list "FILETAGS")))
           (tags (append roam-tags file-tags))
           (tags (seq-map (lambda (tag)
                            (replace-regexp-in-string
                             "[^[:alnum:]_@#%]"
                             "_"
                             tag)) tags))
           (tags (seq-uniq tags)))
      (when tags
        (org-roam-migrate-prop-set "filetags" (org-make-tag-string tags))))
    (let ((case-fold-search t))
      (org-with-point-at 1
        (while (re-search-forward "^#\\+roam_tags:" (point-max) t)
          (beginning-of-line)
          (kill-line 1)))))
  (save-buffer))

(defun org-roam-migrate-get-prop-list (keyword)
  "Return prop list for KEYWORD."
  (let ((re (format "^#\\+%s:[ \t]*\\([^\n]+\\)" (upcase keyword)))
        lst)
    (goto-char (point-min))
    (while (re-search-forward re 2048 t)
      (setq lst (append lst (split-string-and-unquote
                             (buffer-substring-no-properties
                              (match-beginning 1) (match-end 1))))))
    lst))

(defun org-roam-migrate-prop-set (name value)
  "Set a file property called NAME to VALUE in buffer file.
If the property is already set, replace its value."
  (setq name (downcase name))
  (org-with-point-at 1
    (let ((case-fold-search t))
      (if (re-search-forward (concat "^#\\+" name ":\\(.*\\)")
                             (point-max) t)
          (replace-match (concat "#+" name ": " value) 'fixedcase)
        (while (and (not (eobp))
                    (looking-at "^[#:]"))
          (if (save-excursion (end-of-line) (eobp))
              (progn
                (end-of-line)
                (insert "\n"))
            (forward-line)
            (beginning-of-line)))
        (insert "#+" name ": " value "\n")))))

(defun org-roam-migrate-replace-file-links-with-id ()
  "Replace all file: links with ID links in current buffer."
  (org-with-point-at 1
    (while (re-search-forward org-link-bracket-re nil t)
      (let* ((mdata (match-data))
             (path (match-string 1))
             (desc (match-string 2)))
        (when (string-prefix-p "file:" path)
          (setq path (expand-file-name (substring path 5)))
          (when-let ((node-id (caar (org-roam-db-query [:select [id] :from nodes
                                                        :where (= file $s1)
                                                        :and (= level 0)] path))))
            (set-match-data mdata)
            (replace-match (org-link-make-string (concat "id:" node-id)
                                                 desc) nil t)))))))

(provide 'org-roam-migrate)
;;; org-roam-migrate.el ends here

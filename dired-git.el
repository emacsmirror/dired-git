;;; dired-git.el --- Git integration for dired  -*- lexical-binding: t; -*-

;; Copyright (C) 2019  Naoya Yamashita

;; Author: Naoya Yamashita <conao3@gmail.com>
;; Version: 0.0.1
;; Keywords: tools
;; Package-Requires: ((emacs "26.1") (async-await "1.0") (async "1.9.4"))
;; URL: https://github.com/conao3/dired-git.el

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
;; See the GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Git integration for dired.


;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'dired)
(require 'async-await)

(defgroup dired-git nil
  "Git integration for dired."
  :prefix "dired-git-"
  :group 'tools
  :link '(url-link :tag "Github" "https://github.com/conao3/dired-git.el"))

(defface dired-git-branch-master
  '((t (:foreground "green" :weight bold)))
  "Face of showing branch master.")

(defface dired-git-branch-else
  '((t (:foreground "cyan" :weight bold)))
  "Face of showing branch else.")


;;; Manage Overlays

(defun dired-git--add-overlay (pos string)
  "Add overlay to display STRING at POS."
  (let ((ov (make-overlay (1- pos) pos)))
    (overlay-put ov 'dired-git-overlay t)
    (overlay-put ov 'after-string string)))

(defun dired-git--overlays-in (beg end)
  "Get all dired-git overlays between BEG to END."
  (cl-remove-if-not
   (lambda (ov)
     (overlay-get ov 'dired-git-overlay))
   (overlays-in beg end)))

(defun dired-git--overlays-at (pos)
  "Get dired-git overlays at POS."
  (apply #'dired-git--overlays-in `(,pos ,pos)))

(defun dired-git--remove-all-overlays ()
  "Remove all `dired-git' overlays."
  (save-restriction
    (widen)
    (mapc #'delete-overlay (dired-git--overlays-in (point-min) (point-max)))))


;;; Function

(defun dired-git--promise-git-info (dir)
  "Return promise to get branch name for DIR."
  (promise-then
   (let ((default-directory dir))
     (promise:make-process
      shell-file-name
      shell-command-switch
      "find . -mindepth 1 -maxdepth 1 -type d | sort | tr \\\\n \\\\0 | \
xargs -0 -I^ sh -c \"
cd ^
function gitinfo() {
if [ \\$PWD != \\$(git rev-parse --show-toplevel) ]; then exit 1; fi
branch=\\$(git symbolic-ref --short HEAD)
remote=\\$(git config --get branch.\\${branch}.remote)
ff=\\$(git rev-parse \\${remote}/\\${branch} >/dev/null 2>&1;
  if [ 0 -ne \\$? ]; then
    echo missing
  else
    if [ 0 -eq \\$(git rev-list --count \\${remote}/\\${branch}..\\${branch}) ]; then echo true; else echo false; fi
  fi
)
echo \\\"(\
 :file \\\\\\\"\\$PWD\\\\\\\"\
 :branch \\\\\\\"\\${branch}\\\\\\\"\
 :remote \\\\\\\"\\${remote}\\\\\\\"\
 :ff \\\\\\\"\\${ff}\\\\\\\"\
)\\\"
}
gitinfo\"
"))
   (lambda (res)
     (seq-let (stdout stderr) res
       (if (not (string-empty-p stderr))
           (promise-reject `(fail-git-info-invalid-output ,stdout ,stderr))
         (promise-resolve stdout))))
   (lambda (reason)
     (promise-reject `(fail-git-info-command ,reason)))))

(defun dired-git--promise-create-hash-table (stdout)
  "Return promise to create hash table from STDOUT.
STDOUT is return value form `dired-git--promise-git-info'."
  (promise-then
   (promise:async-start
    `(lambda ()
       (require 'subr-x)
       (let ((info (read (format "(%s)" ,stdout)))
             (table (make-hash-table :test 'equal))
             width-alist)
         (dolist (elm info)
           (puthash (plist-get elm :file)
                    `((branch . ,(plist-get elm :branch))
                      (remote . ,(plist-get elm :remote))
                      (ff . ,(plist-get elm :ff)))
                    table)
           (dolist (key '(:branch :remote :ff))
             (when-let ((width (string-width (plist-get elm key))))
               (when (< (or (alist-get key width-alist) 0) width)
                 (setf (alist-get key width-alist) width)))))
         (puthash "**dired-git--width**" width-alist table)
         table)))
   (lambda (res)
     (promise-resolve res))
   (lambda (reason)
     (promise-reject `(fail-create-hash-table ,stdout ,reason)))))

(defun dired-git--promise-add-annotation (buf table)
  "Add git annotation for BUF.
TABLE is hash table returned value by `dired-git--promise-git-info'."
  (with-current-buffer buf
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let ((data (gethash (dired-get-filename nil 'noerror) table)))
          (dired-git--add-overlay
           (point)
           (format "%s-%s-%s "
                   (plist-get data :branch)
                   (plist-get data :remote)
                   (plist-get data :ff))))
        (dired-next-line 1)))))

(async-defun dired-git--add-status (&optional buf rootonly)
  "Add git status for BUF or `current-buffer'.
If ROOTONLY is non-nil, do nothing when DIR doesn't git root directory."
  (condition-case err
      (let* ((buf* (or buf (current-buffer)))
             (res (await (dired-git--promise-git-info
                          (with-current-buffer buf* dired-directory))))
             (res (await (dired-git--promise-create-hash-table res)))
             (res (await (dired-git--promise-add-annotation buf* res)))))
    (error
     (pcase err
       (`(error (fail-git-command ,reason))
        (warn "Fail invoke git command
  buffer: %s\n  rootonly: %s\n  reason:%s"
              (prin1-to-string buf) rootonly reason))
       (`(error (fail-git-info-invalid-output ,stdout ,stderr))
        (warn "Fail invoke git command.  Include stderr output
  buffer: %s\n  rootonly: %s\n  stdout: %s\n  stderr: %s"
              (prin1-to-string buf) rootonly stdout stderr))
       (`(error (fail-create-hash-table ,stdout ,reason))
        (warn "Fail create hash table
  buffer: %s\n  rootonly: %s\n  stdout: %s\n  reason: %s"
              (prin1-to-string buf) rootonly stdout reason))
       (_
        (warn "Fail dired-git--promise-add-annotation
  buffer: %s\n  rootonly: %s\n"
              (prin1-to-string buf) rootonly))))))


;;; Main

;;;###autoload
(defun dired-git-setup (&optional buf)
  "Setup dired-git for BUF or `current-buffer'."
  (interactive)
  (let ((buf* (or buf (current-buffer))))
    (dired-git--add-status buf*)))

(provide 'dired-git)

;; Local Variables:
;; indent-tabs-mode: nil
;; End:

;;; dired-git.el ends here

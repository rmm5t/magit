;;; magit-bookmark.el --- bookmark support for Magit  -*- lexical-binding: t -*-

;; Copyright (C) 2010-2019  The Magit Project Contributors
;;
;; You should have received a copy of the AUTHORS.md file which
;; lists all contributors.  If not, see http://magit.vc/authors.

;; Author: Yuri Khan <yuri.v.khan@gmail.com>
;; Maintainer: Jonas Bernoulli <jonas@bernoul.li>

;; Magit is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; Magit is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
;; or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
;; License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with Magit.  If not, see http://www.gnu.org/licenses.

;;; Commentary:

;; Support for bookmarks for most Magit buffers.

;;; Code:

(eval-when-compile
  (require 'subr-x))

(require 'magit)
(require 'bookmark)

;;; Supporting primitives

(defun magit-bookmark--jump (bookmark fn &rest args)
  "Handle a Magit BOOKMARK.

This function will:

1. Bind `default-directory' to the repository root directory
   stored in the `filename' bookmark property.
2. Invoke the function FN with ARGS as arguments.  This needs to
   restore the buffer.
3. Restore the expanded/collapsed status of top level sections
   and the point position."
  (declare (indent defun))
  (let ((default-directory (bookmark-get-filename bookmark)))
    (if default-directory
        (apply fn args)
      (signal 'bookmark-error-no-filename (list 'stringp default-directory)))
    (when-let ((hidden-sections (bookmark-prop-get bookmark
                                                   'magit-hidden-sections)))
      (dolist (child (oref magit-root-section children))
        (if (member (cons (oref child type)
                          (oref child value))
                    hidden-sections)
            (magit-section-hide child)
          (magit-section-show child))))
    (--when-let (bookmark-get-position bookmark)
      (goto-char it))
    (--when-let (bookmark-get-front-context-string bookmark)
      (when (search-forward it (point-max) t)
        (goto-char (match-beginning 0))))
    (--when-let (bookmark-get-rear-context-string bookmark)
      (when (search-backward it (point-min) t)
        (goto-char (match-end 0))))
    nil))

(defun magit-bookmark--make-record (mode handler &optional name make-props)
  "Create a Magit bookmark.

MODE specifies the expected major mode of current buffer.

HANDLER should be a function that will be used to restore this
buffer.

NAME, if non-nil, is used as the name of the bookmark.

MAKE-PROPS should be either nil or a function that will be called
with `magit-refresh-args' as the argument list, and may return an
alist whose every element has the form (PROP . VALUE) and
specifies additional properties to store in the bookmark."
  (declare (indent 1))
  (unless (eq major-mode mode)
    (user-error "Not in a %s buffer" mode))
  (let ((bookmark (bookmark-make-record-default 'no-file)))
    (bookmark-prop-set bookmark 'handler handler)
    (bookmark-prop-set bookmark 'filename (magit-toplevel))
    (bookmark-prop-set
     bookmark 'magit-hidden-sections
     (--keep (and (oref it hidden)
                  (cons (oref it type)
                        (if (derived-mode-p 'magit-stash-mode)
                            (replace-regexp-in-string
                             (regexp-quote magit-buffer-revision)
                             magit-buffer-revision-hash
                             (oref it value))
                          (oref it value))))
             (oref magit-root-section children)))
    (when name
      (bookmark-prop-set bookmark 'defaults (list name)))
    (when make-props
      (pcase-dolist (`(,prop . ,value) (apply make-props magit-refresh-args))
        (bookmark-prop-set bookmark prop value)))
    bookmark))

;;; Status

;;;###autoload
(defun magit-bookmark--status-jump (bookmark)
  "Handle a Magit status BOOKMARK."
  (magit-bookmark--jump bookmark
    (lambda () (magit-status-setup-buffer default-directory))))

;;;###autoload
(defun magit-bookmark--status-make-record ()
  "Create a Magit status bookmark."
  (magit-bookmark--make-record 'magit-status-mode
    #'magit-bookmark--status-jump))

;;; Refs

;;;###autoload
(defun magit-bookmark--refs-jump (bookmark)
  "Handle a Magit refs BOOKMARK."
  (magit-bookmark--jump bookmark #'magit-show-refs
    (bookmark-prop-get bookmark 'magit-refs)
    (bookmark-prop-get bookmark 'magit-args)))

;;;###autoload
(defun magit-bookmark--refs-make-record ()
  "Create a Magit refs bookmark."
  (magit-bookmark--make-record 'magit-refs-mode
    #'magit-bookmark--refs-jump nil
    (lambda ()
      `((magit-refs . ,magit-buffer-revision)
        (magit-args . ,magit-buffer-arguments)))))

;;; Log

;;;###autoload
(defun magit-bookmark--log-jump (bookmark)
  "Handle a Magit log BOOKMARK."
  (magit-bookmark--jump bookmark #'magit-log-other
    (bookmark-prop-get bookmark 'magit-revs)
    (bookmark-prop-get bookmark 'magit-args)
    (bookmark-prop-get bookmark 'magit-files)))

(defun magit-bookmark--log-make-name ()
  "Generate the default name for a log bookmark."
  (concat (buffer-name) " "
          (mapconcat #'identity magit-buffer-revisions " ")
          (and magit-buffer-log-files
               (concat " touching "
                       (mapconcat #'identity magit-buffer-log-files " ")))))

;;;###autoload
(defun magit-bookmark--log-make-record ()
  "Create a Magit log bookmark."
  (magit-bookmark--make-record 'magit-log-mode
    #'magit-bookmark--log-jump
    #'magit-bookmark--log-make-name
    (lambda ()
      `((magit-revs  . ,magit-buffer-revisions)
        (magit-args  . ,magit-buffer-log-args)
        (magit-files . ,magit-buffer-log-files)))))

;;; Reflog

;;;###autoload
(defun magit-bookmark--reflog-jump (bookmark)
  "Handle a Magit reflog BOOKMARK."
  (magit-bookmark--jump bookmark
    (lambda ()
      (magit-reflog-setup-buffer (bookmark-prop-get bookmark 'magit-ref)
                                 (bookmark-prop-get bookmark 'magit-args)))))

(defun magit-bookmark--reflog-make-name ()
  "Generate the default name for a reflog bookmark."
  (concat (buffer-name) " " magit-buffer-refname))

;;;###autoload
(defun magit-bookmark--reflog-make-record ()
  "Create a Magit reflog bookmark."
  (magit-bookmark--make-record 'magit-reflog-mode
    #'magit-bookmark--reflog-jump
    #'magit-bookmark--reflog-make-name
    (lambda ()
      `((magit-ref  . ,magit-buffer-refname)
        (magit-args . ,magit-buffer-log-args)))))

;;; Stashes

;;;###autoload
(defun magit-bookmark--stashes-jump (bookmark)
  "Handle a Magit stash list BOOKMARK."
  (magit-bookmark--jump bookmark #'magit-stash-list))

;;;###autoload
(defun magit-bookmark--stashes-make-record ()
  "Create a Magit stash list bookmark."
  (magit-bookmark--make-record 'magit-stashes-mode
    #'magit-bookmark--stashes-jump))

;;; Cherry

;;;###autoload
(defun magit-bookmark--cherry-jump (bookmark)
  "Handle a Magit cherry BOOKMARK."
  (magit-bookmark--jump bookmark #'magit-cherry
    (bookmark-prop-get bookmark 'magit-head)
    (bookmark-prop-get bookmark 'magit-upstream)))

(defun magit-bookmark--cherry-make-name ()
  "Generate the default name for a cherry bookmark."
  (concat (buffer-name) " " magit-buffer-refname
          " upstream " magit-buffer-upstream))

;;;###autoload
(defun magit-bookmark--cherry-make-record ()
  "Create a Magit cherry bookmark."
  (magit-bookmark--make-record 'magit-cherry-mode
    #'magit-bookmark--cherry-jump
    #'magit-bookmark--cherry-make-name
    (lambda ()
      `((magit-head     . ,magit-buffer-refname)
        (magit-upstream . ,magit-buffer-upstream)))))

;;; Diff

;;;###autoload
(defun magit-bookmark--diff-jump (bookmark)
  "Handle a Magit diff BOOKMARK."
  (magit-bookmark--jump bookmark #'magit-diff-setup-buffer
    (bookmark-prop-get bookmark 'magit-rev-or-range)
    (bookmark-prop-get bookmark 'magit-const)
    (bookmark-prop-get bookmark 'magit-args)
    (bookmark-prop-get bookmark 'magit-files)))

(defun magit-bookmark--resolve (rev-or-range)
  "Return REV-OR-RANGE with ref names resolved to commit hashes."
  (pcase (magit-git-lines "rev-parse" rev-or-range)
    (`(,rev)
     (magit-rev-abbrev rev))
    ((and `(,rev1 ,rev2)
          (guard (/= ?^ (aref rev1 0)))
          (guard (=  ?^ (aref rev2 0))))
     (concat (magit-rev-abbrev (substring rev2 1))
             ".."
             (magit-rev-abbrev rev1)))
    ((and `(,rev1 ,rev2 ,rev3)
          (guard (/= ?^ (aref rev1 0)))
          (guard (/= ?^ (aref rev2 0)))
          (guard (=  ?^ (aref rev3 0))))
     (ignore rev3)
     (concat (magit-rev-abbrev rev1)
             "..."
             (magit-rev-abbrev rev2)))
    (_
     rev-or-range)))

(defun magit-bookmark--diff-make-name (rev-or-range const _args files)
  "Generate a default name for a diff bookmark."
  (if (member "--no-index" const)
      (apply #'format "*magit-diff %s %s" files)
    (concat (buffer-name) " "
            (cond ((magit-bookmark--resolve rev-or-range))
                  ((member "--cached" const) "staged")
                  (t                       "unstaged"))
            (and files
                 (concat " in " (mapconcat #'identity files ", "))))))

;;;###autoload
(defun magit-bookmark--diff-make-record ()
  "Create a Magit diff bookmark."
  (magit-bookmark--make-record 'magit-diff-mode
    #'magit-bookmark--diff-jump
    #'magit-bookmark--diff-make-name
    (lambda (rev-or-range const args files)
      `((magit-rev-or-range . ,(magit-bookmark--resolve rev-or-range))
        (magit-const        . ,const)
        (magit-args         . ,args)
        (magit-files        . ,files)))))

;;; Revision

;;;###autoload
(defun magit-bookmark--revision-jump (bookmark)
  "Handle a Magit revision BOOKMARK."
  (magit-bookmark--jump bookmark #'magit-show-commit
    (bookmark-prop-get bookmark 'magit-rev)
    (bookmark-prop-get bookmark 'magit-args)
    (bookmark-prop-get bookmark 'magit-files)))

(defun magit-bookmark--revision-make-name (_rev _ _args files)
  "Generate a default name for a revision bookmark."
  (concat (buffer-name) " "
          (magit-rev-abbrev magit-buffer-revision)
          (if files
              (concat " " (mapconcat #'identity files " "))
            (when-let ((subject (magit-rev-format "%s" magit-buffer-revision)))
              (concat " " subject)))))

;;;###autoload
(defun magit-bookmark--revision-make-record ()
  "Create a Magit revision bookmark."
  ;; magit-refresh-args stores the revision in relative form.
  ;; For bookmarks, the exact hash is more appropriate.
  (magit-bookmark--make-record 'magit-revision-mode
    #'magit-bookmark--revision-jump
    #'magit-bookmark--revision-make-name
    (lambda (_rev _ args files)
      `((magit-rev   . ,magit-buffer-revision-hash)
        (magit-args  . ,args)
        (magit-files . ,files)))))

;;; Stash

;;;###autoload
(defun magit-bookmark--stash-jump (bookmark)
  "Handle a Magit stash BOOKMARK."
  (magit-bookmark--jump bookmark #'magit-stash-show
    (bookmark-prop-get bookmark 'magit-stash)
    (bookmark-prop-get bookmark 'magit-args)
    (bookmark-prop-get bookmark 'magit-files)))

(defun magit-bookmark--stash-make-name ()
  "Generate the default name for a stash bookmark."
  (concat (buffer-name) " "
          magit-buffer-revision-hash " "
          (if magit-buffer-diff-files
              (mapconcat #'identity magit-buffer-diff-files " ")
            (magit-rev-format "%s" magit-buffer-revision))))

;;;###autoload
(defun magit-bookmark--stash-make-record ()
  "Create a Magit stash bookmark."
  (magit-bookmark--make-record 'magit-stash-mode
    #'magit-bookmark--stash-jump
    #'magit-bookmark--stash-make-name
    (lambda (&rest _)
      `((magit-stash . ,magit-buffer-revision-hash)
        (magit-args  . ,magit-buffer-diff-args)
        (magit-files . ,magit-buffer-diff-files)))))

;;; Submodules

;;;###autoload
(defun magit-bookmark--submodules-jump (bookmark)
  "Handle a Magit submodule list BOOKMARK."
  (magit-bookmark--jump bookmark #'magit-list-submodules))

;;;###autoload
(defun magit-bookmark--submodules-make-record ()
  "Create a Magit submodule list bookmark."
  (magit-bookmark--make-record 'magit-submodule-list-mode
    #'magit-bookmark--submodules-jump))

;;; _
(provide 'magit-bookmark)
;;; magit-bookmark.el ends here

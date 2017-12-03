;;; Copyright © 2016, 2017  Roel Janssen <roel@gnu.org>
;;; Copyright © 2017  Ricardo Wurmus <rekado@elephly.net>
;;;
;;; This program is free software: you can redistribute it and/or
;;; modify it under the terms of the GNU Affero General Public License
;;; as published by the Free Software Foundation, either version 3 of
;;; the License, or (at your option) any later version.
;;;
;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;; Affero General Public License for more details.
;;;
;;; You should have received a copy of the GNU Affero General Public
;;; License along with this program.  If not, see
;;; <http://www.gnu.org/licenses/>.

(use-modules (commonmark)
             (gnu packages)
             (guix licenses)
             (guix packages)
             (guix records)
             (guix utils)
             (ice-9 getopt-long)
             (ice-9 match)
             (ice-9 rdelim)
             (json)
             (rnrs bytevectors)
             (rnrs io ports)
             (srfi srfi-1)
             (sxml simple)
             (web request)
             (web response)
             (web server)
             (web uri)
             (www config)
             (www pages error)
             (www pages javascript)
             (www pages package)
             (www pages welcome)
             (www pages)
             (www util))

;; ----------------------------------------------------------------------------
;; HANDLERS
;; ----------------------------------------------------------------------------
;;
;; The way a request is handled varies upon the nature of the request.  It can
;; be as simple as serving a pre-existing file, or as complex as finding a
;; Scheme module to use for handling the request.
;;
;; In this section, the different handlers are implemented.
;;

(define (request-markdown-handler request-path)
  (let ((file (string-append %www-markdown-root "/" request-path ".md")))
    (values
     '((content-type . (text/html)))
     (call-with-output-string
       (lambda (port)
         (set-port-encoding! port "utf8")
         (format port "<!DOCTYPE html>~%")
         (sxml->xml (page-root-template
                     (string-capitalize
                      (string-replace-occurrence
                       (basename request-path) #\- #\ ))
                     request-path
                     (if (defined? 'site-config)
                         site-config
                         '())
                     (call-with-input-file file
                       (lambda (port) (commonmark->sxml port)))) port))))))

(define (request-packages-json-handler)
  (let* ((packages-file (string-append %www-root "/packages.json"))
         (cache-timeout-file (string-append %www-root "/cache.timeout"))
         (cache-timeout-exists? (access? cache-timeout-file F_OK)))
    ;; Write the packages JSON to disk to speed up the page load.
    ;; This caching mechanism prevents new packages from propagating
    ;; into the search.  For this, we can manually create a file
    ;; "cache.timeout" in the %www-root.
    (when (or (not (access? packages-file F_OK))
              (access? cache-timeout-file F_OK))
      (let ((all-packages (fold-packages cons '()))
            (package->json (lambda (package)
                             (json (object
                                    ("name"     ,(package-name package))
                                    ("version"  ,(package-version package))
                                    ("synopsis" ,(package-synopsis package))
                                    ("homepage" ,(package-home-page package))
                                    ("module"   ,(string-drop-right
                                                  (last (string-split (location-file
                                                                       (package-location package))
                                                                      #\/))
                                                  4)))))))
        (with-atomic-file-output packages-file
          (lambda (port)
            (scm->json (map package->json
                            (if (defined? 'site-config)
                                (remove (lambda (package)
                                          (member (package-name package)
                                                  (hpcweb-configuration-blacklist site-config)))
                                        all-packages)
                                all-packages))
                       port)))
        (when cache-timeout-exists?
          (delete-file cache-timeout-file))))
    (request-file-handler "packages.json")))

(define (request-file-handler path)
  "This handler takes data from a file and sends that as a response."

  (define (response-content-type path)
    "This function returns the content type of a file based on its extension."
    (let ((extension (substring path (1+ (string-rindex path #\.)))))
      (cond [(string= extension "css")  '(text/css)]
            [(string= extension "js")   '(application/javascript)]
            [(string= extension "json") '(application/javascript)]
            [(string= extension "html") '(text/html)]
            [(string= extension "png")  '(image/png)]
            [(string= extension "svg")  '(image/svg+xml)]
            [(string= extension "ico")  '(image/x-icon)]
            [(string= extension "pdf")  '(application/pdf)]
            [(string= extension "ttf")  '(application/font-sfnt)]
            [(#t '(text/plain))])))

  (let* ((full-path (string-append %www-root "/" path))
         (file-stat (stat full-path #f)))
    (if (not file-stat)
        (values '((content-type . (text/html)))
                (with-output-to-string
                  (lambda _
                    (sxml->xml (page-error-404 path (if (defined? 'site-config)
                                                        site-config
                                                        '()))))))
        ;; Do not handle files larger than %maximum-file-size.
        ;; Please increase the file size if your server can handle it.
        (if (> (stat:size file-stat) %www-max-file-size)
            (values '((content-type . (text/html)))
                    (with-output-to-string
                      (lambda _ (sxml->xml (page-error-filesize
                                            path (if (defined? 'site-config)
                                                     site-config
                                                     '()))))))
            (values `((content-type . ,(response-content-type full-path)))
                    (with-input-from-file full-path
                      (lambda _
                        (get-bytevector-all (current-input-port)))))))))

(define (request-package-handler request-path)
  (values '((content-type . (text/html)))
          (call-with-output-string
            (lambda (port)
              (sxml->xml (page-package request-path
                                       (if (defined? 'site-config)
                                           site-config
                                           '())) port)))))

(define (request-scheme-page-handler request request-body request-path)
  (format #t "Scheme handler for ~a~%" request-path)
  (values '((content-type . (text/html)))
          (call-with-output-string
            (lambda (port)
              (set-port-encoding! port "utf8")
              (format port "<!DOCTYPE html>~%")
              (if (< (string-length request-path) 2)
                  (sxml->xml (page-welcome "/" (if (defined? 'site-config)
                                                   site-config '())) port)
                  (let* ((function-symbol (string->symbol
                                           (string-map
                                            (lambda (x) (if (eq? x #\/) #\- x))
                                            (substring request-path 1))))
                         (module (resolve-module
                                  (module-path '(www pages)
                                   (string-split (substring request-path 1) #\/))
                                  #:ensure #f))
                         (page-symbol (symbol-append 'page- function-symbol)))
                    (if module
                        (let ((display-function
                               (module-ref module page-symbol)))
                          (format #t "display function has been set to ~a.~%" display-function)
                          (format #t "Response: ~a~%" (display-function request-path
                                                                        (if (defined? 'site-config)
                                                                            site-config '())))
                          (if (eq? (request-method request) 'POST)
                              (sxml->xml (display-function request-path
                                          (if (defined? 'site-config)
                                              site-config '())
                                          #:post-data
                                          (utf8->string request-body)) port)
                              (sxml->xml (display-function request-path
                                           (if (defined? 'site-config)
                                               site-config '())) port)))
                        (sxml->xml (page-error-404 request-path
                                    (if (defined? 'site-config)
                                        site-config '())) port))))))))


;; ----------------------------------------------------------------------------
;; ROUTING & HANDLERS
;; ----------------------------------------------------------------------------
;;
;; Requests can have different handlers.
;; * Static objects (images, stylesheet, javascript files) have their own
;;   handler.
;; * Package pages are generated dynamically, so they have their own handler.
;; * The 'regular' Scheme pages have their own handler that resolves the
;;   module dynamically.
;;
;; Feel free to add your own handler whenever that is necessary.
;;
;; ----------------------------------------------------------------------------
(define (request-handler request request-body)
  (let ((request-path (uri-path (request-uri request))))
    (format #t "~a ~a~%" (request-method request) request-path)
    (cond
     ((string= request-path "/packages.json")
      (request-packages-json-handler))
     ((and (> (string-length request-path) 7)
           (string= (string-take request-path 8) "/static/"))
      (request-file-handler request-path))
     ((and (> (string-length request-path) 8)
           (string= (string-take request-path 9) "/package/"))
      (request-package-handler request-path))
     ((and (not (string= "/" request-path))
           (access? (string-append %www-markdown-root "/"
                                   request-path ".md") F_OK))
      (request-markdown-handler request-path))
     (else
      (request-scheme-page-handler request request-body request-path)))))


;; ----------------------------------------------------------------------------
;; RUNNER
;; ----------------------------------------------------------------------------
;;
;; This code runs the web server.

(define (run-web-interface)
  (run-server request-handler 'http
              `(#:port ,%www-listen-port
                #:addr ,INADDR_ANY)))

(define program-options
  '((version (single-char #\v) (value #f))
    (help    (single-char #\h) (value #f))
    (config  (single-char #\c) (value #t))))

(define (show-help)
  (display "This is hpcguix-web.")
  (newline)
  (display "  --help         Show this message.")
  (newline)
  (display "  --version      Show versioning information.")
  (newline)
  (display "  --config=ARG   Load a site-specific configuration from ARG.")
  (newline))

(let* ((options (getopt-long (command-line) program-options))
       (config-file (option-ref options 'config #f)))
  (cond ((option-ref options 'help #f)
         (show-help))
        ((option-ref options 'version #f)
         (show-version))
        (config-file
         (load config-file)
         (if (defined? 'site-config)
             (format #t "Loaded configuration from ~a~%" config-file)
             (format #t "Please define 'site-config in ~a." config-file))
         (run-web-interface))
        (else
         (run-web-interface))))

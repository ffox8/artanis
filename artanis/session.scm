;;  -*-  indent-tabs-mode:nil; coding: utf-8 -*-
;;  Copyright (C) 2013,2014,2015,2016
;;      "Mu Lei" known as "NalaGinrut" <NalaGinrut@gmail.com>
;;  Artanis is free software: you can redistribute it and/or modify
;;  it under the terms of the GNU General Public License and GNU
;;  Lesser General Public License published by the Free Software
;;  Foundation, either version 3 of the License, or (at your option)
;;  any later version.

;;  Artanis is distributed in the hope that it will be useful,
;;  but WITHOUT ANY WARRANTY; without even the implied warranty of
;;  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;  GNU General Public License and GNU Lesser General Public License
;;  for more details.

;;  You should have received a copy of the GNU General Public License
;;  and GNU Lesser General Public License along with this program.
;;  If not, see <http://www.gnu.org/licenses/>.

(define-module (artanis session)
  #:use-module (artanis utils)
  #:use-module (artanis route)
  #:use-module (artanis db)
  #:use-module (artanis fprm)
  #:use-module (artanis config)
  #:use-module (srfi srfi-9)
  #:use-module ((rnrs) #:select (define-record-type))
  #:use-module (web request)
  #:export (session-set!
            session-ref
            session-expired?
            session-spawn
            session-destory!
            session-restore
            session-from-correct-client?
            add-new-session-backend
            session-init

            session-backend?
            make-session-backend
            session-backend-name
            session-backend-init
            session-backend-store!
            session-backend-destory!
            session-backend-restore
            session-backend-set!
            session-backend-ref))

(define (make-session args)
  (let ((ht (make-hash-table)))
    (for-each (lambda (e)
                (hash-set! ht (car e) (cdr e)))
              args)
    ht))

(define (get-new-sid)
  (get-random-from-dev))

(define (session->alist session)
  (hash-map->list list session))

(define (session-from-correct-client? session rc)
  (let* ((ip (remote-info (rc-req rc)))
         (client (hash-ref session "client"))
         (ret (equal? client ip)))
    (when (not ret)
      (format (current-error-port)
              "[Session Hijack!] Valid sid from different client: ~a!~%" client))
    ret))

(define (new-session rc data expires)
  (let ((expires-str (make-expires expires))
        (ip (remote-info (rc-req rc))))
    (make-session `(("expires" . ,expires-str)
                    ("client"  . ,ip)
                    ("data"    . ,data))))) ; data is assoc list

;; TODO: Support session-engine:
;; session.engine = redis or memcached, for taking advantage of k-v-DB.

;; TODO: session key-values should be flushed into set-cookie in rc, and should be encoded
;;       with base64.

(define-record-type session-backend
  (fields
   name ; symbol
   meta ; anything necessary for a specific backend
   init ; -> session-backend
   store! ; -> session-backend -> string -> hash-table 
   destory! ; -> session-backend -> string
   restore ; -> session-backend -> string
   set! ; -> session-backend -> string -> string -> object
   ref)) ; -> session-backend -> string -> string

;; session.engine = db, for managing sessions with DB support.
(define (backend:session-init/db sb)
  (format (artanis-current-output)
          "Initilizing session backend `~:@(~a~)'...~%" 'db)
  (let* ((mt (map-table-from-DB (session-backend-meta sb)))
         (defs '((sid varchar 40)
                 (data text)
                 (expires datetime)
                 (client varchar 39) ; 39 for IPv6
                 (valid boolean)))) ; FALSE if expired
    (mt 'create 'Sessions defs #:if-exists? 'ignore #:primary-keys '(sid))
    (format (artanis-current-output) "Init session DB backend is done!~%")))

(define (backend:session-store/db sb sid ss)
  (let ((mt (map-table-from-DB (session-backend-meta sb)))
        (expires (hash-ref ss "expires"))
        (client (hash-ref ss "client"))
        (data (object->string (hash-ref ss "data")))
        (valid (hash-ref ss "valid")))
    (mt 'set 'Session #:sid sid #:expires expires #:client client
        #:data data #:valid valid)))

(define (backend:session-destory/db sb sid)
  (let ((mt (map-table-from-DB (session-backend-meta sb))))
    (mt 'set 'Session #:valid 'false)))

(define (backend:session-restore/db sb sid)
  (let* ((mt (map-table-from-DB (session-backend-meta sb)))
         (cnd (where #:sid sid #:valid "true"))
         (valid (mt 'get 'Session #:condition cnd #:ret 'top)))
    (and valid (make-session valid))))

(define (backend:session-set/db sb sid k v)
  (define-syntax-rule (-> x) (and x (call-with-input-string x read)))
  (let* ((mt (map-table-from-DB (session-backend-meta sb)))
         (cnd (where #:sid sid #:valid "true"))
         (data (-> (mt 'ref 'Session #:columns '(data) #:condition cnd))))
    (and data
         (mt 'set 'Session
             #:data (object->string (assoc-set! data k v))
             #:condition cnd))))

(define (backend:session-ref/db sb sid k)
  (define-syntax-rule (-> x) (and x (call-with-input-string x read)))
  (let* ((mt (map-table-from-DB (session-backend-meta sb)))
         (cnd (where #:sid sid #:valid "true"))
         (data (-> (mt 'ref 'Session #:columns '(data) #:condition cnd))))
    (and data (assoc-ref data k))))

(define (new-session-backend/db)
  (make-session-backend 'db
                        (get-conn-from-pool 0)
                        backend:session-init/db
                        backend:session-spawn/db
                        backend:session-destory/db
                        backend:session-restore/db
                        backend:session-set/db
                        backend:session-ref/db))

;; session.engine = simple, for managing sessions with simple memory caching.
(define (backend:session-init/simple sb)
  (format (artanis-current-output)
          "Initilizing session backend `~:@(~a~)'...~%" 'simple))

(define (backend:session-store/simple sb sid ss)
  (hash-set! (session-backend-meta sb) sid ss))

;; FIXME: lock needed?
(define (backend:session-destory/simple sb sid)
  (hash-remove! (session-backend-meta sb) sid))

(define (backend:session-restore/simple sb sid)
  (hash-ref (session-backend-meta sb) sid))

;; FIXME: lock needed?
(define (backend:session-set/simple sb sid k v)
  (cond
   ((backend:session-restore/simple sb sid)
    => (lambda (ss) (hash-set! ss k v)))
   (else
    (throw 'artanis-err 500
     (format (artanis-current-output)
             "Session id (~a) doesn't hit anything!~%" sid)))))

(define (backend:session-ref/simple sb sid k)
  (cond
   ((backend:session-restore/simple sb sid)
    => (lambda (ss) (hash-ref (hash-ref ss "data") k)))
   (else
    (throw 'artanis-err 500
    (format (artanis-current-output)
            "Session id (~a) doesn't hit anything!~%" sid)))))

(define (new-session-backend/simple)
  (make-session-backend 'simple
                        (make-hash-table) ; here, meta is session table
                        backend:session-init/simple
                        backend:session-spawn/simple
                        backend:session-destory/simple
                        backend:session-restore/simple
                        backend:session-set/simple
                        backend:session-ref/simple))

(define (load-session-from-file sid)
  (let ((f (get-session-file sid)))
    (and f ; if cookie file exists
         (call-with-input-file sid read))))

(define (save-session-to-file sid session)
  (let ((s (session->alist session))
        (f (get-session-file sid)))
    ;; if file exists, it'll be removed then create a new one
    (when f 
      (delete-file f)
      (call-with-output-file f
        (lambda (port)
          (write s port))))))

;; session.engine = file, for managing sessions with files.
(define (backend:session-init/file sb)
  (format (artanis-current-output)
          "Initilizing session backend `~:@(~a~)'...~%" 'file)
  (let ((path (get-conf '(session path))))
    (cond
     ((file-is-directory? path)
      (format (artanis-current-output)
              "Session path `~a' exists, keep it for existing sessions!~%"
              path))
     ((not (file-exists? path))
      (mkdir path)
      (format (artanis-current-output)
              "Session path `~a' doesn't exist, created it!~%"
              path))
     (else
      (throw 'artanis-err 500
             (format #f "Session path `~a' conflict with an existed file!~%"
                     path))))))

(define (backend:session-store/file sb sid ss)
  (let ((s (session->alist session)))
    (save-session-to-file sid s)))

(define (backend:session-destory/file sb)
  (let ((f (get-session-file sid)))
    (and f (delete-file f))))

(define (backend:session-restore/file sb sid)
  (let ((f (format #f "~a/~a.session" (get-conf '(session path)) sid)))
    (and (file-exists? f)
         (make-session (load-session-from-file sid)))))

(define (backend:session-set/file sb sid k v)
  (let* ((ss (load-session-from-file sid))
         (data (assoc-ref ss "data")))
    (save-session-to-file
     sid
     (assoc-set! ss "data" (assoc-set! data k v)))))

(define (backend:session-ref/file sb sid k)
  (let ((ss (load-session-from-file sid)))
    (assoc-ref (assoc-ref ss "data") k)))

(define (new-session-backend/file)
  (make-session-backend 'file
                        #f ; here, no meta is needed.
                        backend:session-init/file
                        backend:session-spawn/file
                        backend:session-destory/file
                        backend:session-restore/file
                        backend:session-set/file
                        backend:session-ref/file))

(define (session-set! sid k v)
  ((session-backend-set! (current-session-backend))
   (current-session-backend)
   k v))
  
(define (session-ref sid k)
  ((session-backend-ref (current-session-backend))
   (current-session-backend)
   k))

(define (session-destory! sid)
  ((session-backend-destroy (current-session-backend))
   (current-session-backend)
   sid))

(define (session-expired? session)
  (let ((expir (hash-ref session "expires")))
    (and expir (time-expired? expir))))

(define (session-restore sid)
  (let ((session ((session-backend-restore (current-session-backend))
                  (current-session-backend) sid)))
    (and session (if (session-expired? session) ; expired then return #f
                     (begin (session-destory! sid) #f)
                     session)))) ; non-expired, return session
;; if no session then return #f

(define (store-session sid session)
  ((session-backend-store! (current-session-backend))
   (current-session-backend)
   sid session)
  session)

(define* (session-spawn rc #:key (data '()) (expires 3600))
  (let* ((sid (get-new-sid))
         (session (or (session-restore sid)
                      (store-session sid (new-session rc data expires)))))
    (format (artanis-current-output) "Session spawned: sid - ~a, data - ~a~%" sid data)
    (values sid session)))

(define *session-backend-table*
  `((simple . new-session-backend/simple)
    (db     . new-session-backend/db)
    (file   . new-session-backend/file)))

(define (add-new-session-backend name maker)
  (set! *session-backend-table*
        (assoc-set! *session-backend-table* name maker)))

(define (session-init)
  (let ((maker))
    (cond
     ((assoc-ref *session-backend-table* (get-conf '(session backend)))
      => (lambda (maker) (maker)))
     (else (error (format #f "Invalid session backdend: ~:@(~a~)"
                          (get-conf '(session backend))))))))

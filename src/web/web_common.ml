open Lwt
open Util
open Serializable_builtin_t
open Serializable_t

type user_type = Dummy | CAS | Admin

type user = {
  user_name : string;
  user_type : user_type;
}

let string_of_user {user_name; user_type} =
  match user_type with
    | Dummy -> Printf.sprintf "dummy:%s" user_name
    | CAS -> user_name
    | Admin -> Printf.sprintf "admin:%s" user_name

let is_admin = function
  | Some { user_name = _; user_type = Admin } -> true
  | _ -> false

type acl =
  | Any
  | Restricted of (user -> bool Lwt.t)

module SSet = Set.Make(String)

type election_data = {
  fn_election : string;
  fingerprint : string;
  election : ff_pubkey election;
  fn_public_keys : string;
  public_creds : SSet.t;
  featured_p : bool;
  can_read : acl;
  can_vote : acl;
}

let enforce_single_element s =
  let open Lwt_stream in
  lwt t = next s in
  lwt b = is_empty s in
  (assert_lwt b) >>
  Lwt.return t

let load_from_file read fname =
  let i = open_in fname in
  let buf = Lexing.from_channel i in
  let lex = Yojson.init_lexer ~fname () in
  let result = read lex buf in
  close_in i;
  result

module MakeLwtRandom (G : Signatures.GROUP) = struct

  type 'a t = 'a Lwt.t
  let return = Lwt.return
  let bind = Lwt.bind
  let fail = Lwt.fail

  let prng = Lwt_preemptive.detach (fun () ->
    Cryptokit.Random.(pseudo_rng (string secure_rng 16))
  ) ()

  let random q =
    let size = Z.size q * Sys.word_size / 8 in
    lwt prng = prng in
    let r = Cryptokit.Random.string prng size in
    return Z.(of_bits r mod q)

end

type error =
  | Serialization of exn
  | ProofCheck
  | ElectionClosed
  | MissingCredential
  | InvalidCredential
  | RevoteNotAllowed
  | ReusedCredential
  | WrongCredential
  | UsedCredential
  | CredentialNotFound

exception Error of error

let fail e = Lwt.fail (Error e)

let explain_error = function
  | Serialization e ->
    Printf.sprintf "your ballot has a syntax error (%s)" (Printexc.to_string e)
  | ProofCheck -> "some proofs failed verification"
  | ElectionClosed -> "the election is closed"
  | MissingCredential -> "a credential is missing"
  | InvalidCredential -> "your credential is invalid"
  | RevoteNotAllowed -> "you are not allowed to revote"
  | ReusedCredential -> "your credential has already been used"
  | WrongCredential -> "you are not allowed to vote with this credential"
  | UsedCredential -> "the credential has already been used"
  | CredentialNotFound -> "the credential has not been found"

module type LWT_ELECTION = Signatures.ELECTION
  with type elt = Z.t
  and type 'a m = 'a Lwt.t

module type WEB_BBOX = sig
  include Signatures.BALLOT_BOX
  with type 'a m := 'a Lwt.t
  and type ballot = string
  and type record = string * datetime

  val inject_creds : SSet.t -> unit Lwt.t
  val extract_creds : unit -> SSet.t Lwt.t
  val update_cred : old:string -> new_:string -> unit Lwt.t
end

let security_logfile = ref None

let open_security_log f =
  lwt () =
    match !security_logfile with
      | Some ic -> Lwt_io.close ic
      | None -> return ()
  in
  lwt ic = Lwt_io.(
    open_file ~flags:Unix.(
      [O_WRONLY; O_APPEND; O_CREAT]
    ) ~perm:0o600 ~mode:output f
  ) in
  security_logfile := Some ic;
  return ()

let security_log s =
  match !security_logfile with
    | None -> return ()
    | Some ic -> Lwt_io.atomic (fun ic ->
      Lwt_io.write ic (
        Serializable_builtin_j.string_of_datetime (
          CalendarLib.Fcalendar.Precise.now (),
          None
        )
      ) >>
      Lwt_io.write ic ": " >>
      Lwt_io.write_line ic (s ()) >>
      Lwt_io.flush ic
    ) ic

module MakeBallotBox (P : Signatures.ELECTION_PARAMS) (E : LWT_ELECTION) = struct

  (* TODO: enforce E is derived from P *)

  let suffix = "_" ^ String.map (function
    | '-' -> '_'
    | c -> c
  ) (Uuidm.to_string E.election_params.e_uuid)

  let ballot_table = Ocsipersist.open_table ("ballots" ^ suffix)
  let record_table = Ocsipersist.open_table ("records" ^ suffix)
  let cred_table = Ocsipersist.open_table ("creds" ^ suffix)

  type ballot = string
  type record = string * Serializable_builtin_t.datetime

  let extract_creds () =
    Ocsipersist.fold_step (fun k v x ->
      return (SSet.add k x)
    ) cred_table SSet.empty

  let inject_creds creds =
    lwt existing_creds = extract_creds () in
    if SSet.is_empty existing_creds then (
      Ocsigen_messages.debug (fun () ->
        "-- injecting credentials"
      );
      SSet.fold (fun x unit ->
        unit >> Ocsipersist.add cred_table x None
      ) creds (return ())
    ) else (
      if SSet.(is_empty (diff creds existing_creds)) then (
        Lwt.return ()
      ) else (
        Lwt.fail (Invalid_argument "Existing credentials do not match")
      )
    )

  let cast rawballot (user, date) =
    let voting_open = match P.metadata with
      | Some m ->
        let date = fst date in
        let open CalendarLib.Fcalendar.Precise in
        compare (fst m.e_voting_starts_at) date <= 0 &&
        compare date (fst m.e_voting_ends_at) < 0
      | None -> true
    in
    if not voting_open then fail ElectionClosed else return () >>
    if String.contains rawballot '\n' then (
      fail (Serialization (Invalid_argument "multiline ballot"))
    ) else return () >>
    lwt ballot =
      try Lwt.return (
        Serializable_j.ballot_of_string
          Serializable_builtin_j.read_number rawballot
      ) with e -> fail (Serialization e)
    in
    lwt credential =
      match ballot.signature with
        | Some s -> Lwt.return (Z.to_string s.s_commitment)
        | None -> fail MissingCredential
    in
    lwt old_cred =
      try_lwt Ocsipersist.find cred_table credential
      with Not_found -> fail InvalidCredential
    and old_record =
      try_lwt
        lwt x = Ocsipersist.find record_table user in
        Lwt.return (Some x)
      with Not_found -> Lwt.return None
    in
    match old_cred, old_record with
      | None, None ->
        (* first vote *)
        if E.check_ballot ballot then (
          let hash = sha256_b64 rawballot in
          Ocsipersist.add cred_table credential (Some hash) >>
          Ocsipersist.add ballot_table hash rawballot >>
          Ocsipersist.add record_table user (date, credential) >>
          security_log (fun () ->
            Printf.sprintf "%s successfully cast ballot %s" user hash
          )
        ) else (
          fail ProofCheck
        )
      | Some h, Some (_, old_credential) ->
        (* revote *)
        if credential = old_credential then (
          if E.check_ballot ballot then (
            lwt old_ballot = Ocsipersist.find ballot_table h in
            Ocsipersist.remove ballot_table h >>
            security_log (fun () ->
              Printf.sprintf "%s successfully removed ballot %S" user old_ballot
            ) >>
            let hash = sha256_b64 rawballot in
            Ocsipersist.add cred_table credential (Some hash) >>
            Ocsipersist.add ballot_table hash rawballot >>
            Ocsipersist.add record_table user (date, credential) >>
            security_log (fun () ->
              Printf.sprintf "%s successfully cast ballot %s" user hash
            )
          ) else (
            fail ProofCheck
          )
        ) else (
          security_log (fun () ->
            Printf.sprintf "%s attempted to revote with already used credential %s" user credential
          ) >> fail WrongCredential
        )
      | None, Some _ ->
        security_log (fun () ->
          Printf.sprintf "%s attempted to revote using a new credential %s" user credential
        ) >> fail RevoteNotAllowed
      | Some _, None ->
        security_log (fun () ->
          Printf.sprintf "%s attempted to vote with already used credential %s" user credential
        ) >> fail ReusedCredential

  let fold_ballots f x =
    Ocsipersist.fold_step (fun k v x -> f v x) ballot_table x

  let fold_records f x =
    Ocsipersist.fold_step (fun k v x -> f (k, fst v) x) record_table x

  let turnout = Ocsipersist.length ballot_table

  let update_cred ~old ~new_ =
    match_lwt Ocsipersist.fold_step (fun k v x ->
      if sha256_hex k = old then (
        match v with
          | Some _ -> fail UsedCredential
          | None -> return (Some k)
      ) else return x
    ) cred_table None with
    | None -> fail CredentialNotFound
    | Some x ->
      Ocsipersist.remove cred_table x >>
      Ocsipersist.add cred_table new_ None
end

module type WEB_ELECTION = sig
  module G : Signatures.GROUP
  module P : Signatures.ELECTION_PARAMS
  module E : LWT_ELECTION
  module B : WEB_BBOX
  val data : election_data
end

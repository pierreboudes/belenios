open StdExtra
open Helios_datatypes_t

module type TYPES = sig
  type elt
  type 'a t
  val read : 'a t -> Yojson.Safe.lexer_state -> Lexing.lexbuf -> 'a
  val write : 'a t -> Bi_outbuf.t -> 'a -> unit
  val election : elt election t
  val private_key : elt private_key t
  val trustee_public_key : elt trustee_public_key t
  val vote : elt vote t
  val encrypted_tally : elt encrypted_tally t
  val partial_decryption : elt partial_decryption t
  val election_public_data : elt election_public_data t
  val election_private_data : elt election_private_data t
end

module type SGROUP = sig
  type t
  val write : Bi_outbuf.t -> t -> unit
  val read : Yojson.Safe.lexer_state -> Lexing.lexbuf -> t
end

module SFiniteFieldMult : SGROUP with type t = Z.t = struct
  type t = Z.t
  let write = Core_datatypes_j.write_number
  let read = Core_datatypes_j.read_number
end

module MakeTypes (G : SGROUP) : TYPES with type elt = G.t = struct
  open Helios_datatypes_j
  type elt = G.t
  type 'a t = (Yojson.Safe.lexer_state -> Lexing.lexbuf -> 'a) * (Bi_outbuf.t -> 'a -> unit)
  let read = fst
  let write = snd
  let election = (read_election G.read, write_election G.write)
  let private_key = (read_private_key G.read, write_private_key G.write)
  let trustee_public_key = (read_trustee_public_key G.read, write_trustee_public_key G.write)
  let vote = (read_vote G.read, write_vote G.write)
  let encrypted_tally = (read_encrypted_tally G.read, write_encrypted_tally G.write)
  let partial_decryption = (read_partial_decryption G.read, write_partial_decryption G.write)
  let election_public_data = (read_election_public_data G.read, write_election_public_data G.write)
  let election_private_data = (read_election_private_data G.read, write_election_private_data G.write)
end

module Types : TYPES with type elt = Z.t = MakeTypes (SFiniteFieldMult)

let load typ fname = load_from_file (Types.read typ) fname

let save typ fname x =
  let o = open_out fname in
  let buf = Bi_outbuf.create_channel_writer o in
  Types.write typ buf x;
  Bi_outbuf.flush_channel_writer buf;
  close_out o

let load_and_check ?(verbose=false) typ fname =
  if verbose then Printf.eprintf "Loading and checking %s...\n%!" fname;
  let thing = load typ fname in
  let tempfname = Filename.temp_file "belenios" ".json" in
  save typ tempfname thing;
  let r = Printf.ksprintf Sys.command "bash -c 'diff -u <(json_pp < %s) <(json_pp < %s)'" fname tempfname in
  assert (r = 0);
  Sys.remove tempfname;
  thing

type 'a election_test_data = {
  raw : string;
  fingerprint : string;
  election : 'a election;
  votes : 'a vote array option;
  public_data : 'a election_public_data;
  private_data : 'a election_private_data;
}

let enforce_single_element s =
  let open Lwt_stream in
  lwt t = next s in
  lwt b = is_empty s in
  (assert_lwt b) >>
  Lwt.return t

let load_election_test_data ?(verbose=false) dir =
  let data x = Filename.concat dir x in
  let raw =
    Lwt_io.lines_of_file (data "election.json") |>
    enforce_single_element |> Lwt_main.run
  in
  let election = Helios_datatypes_j.election_of_string Core_datatypes_j.read_number raw in
  let public_data = load_and_check ~verbose Types.election_public_data (data "public.json") in
  let private_data = load_and_check ~verbose Types.election_private_data (data "private.json") in
  let fingerprint = hashB raw in
  let votes =
    let file = data "votes.json" in
    if Sys.file_exists file then Some (
      non_empty_lines_of_file file |>
      Lwt_main.run |>
      List.map (Helios_datatypes_j.vote_of_string Core_datatypes_j.read_number) |>
      Array.of_list
    ) else None
  in
  { raw; fingerprint; election; votes; public_data; private_data }

let verbose_assert msg it =
  Printf.eprintf "   %s...%!" msg;
  let r = Lazy.force it in
  Printf.eprintf " %s\n%!" (if r then "OK" else "failed!")

let verbose_verify_election_test_data e =
  Printf.eprintf "Verifying election %S:\n%!" e.election.e_short_name;
  let {g; p; q; y} = e.election.e_public_key in
  let module G = (val ElGamal.make_ff_msubgroup p q g : ElGamal.GROUP with type t = Z.t) in
  let module Crypto = ElGamal.Make (G) in
  verbose_assert "election key" (lazy (
    Crypto.verify_election_key
      e.election.e_public_key.y
      e.public_data.public_keys
  ));
  (match e.votes with
    | Some votes ->
      verbose_assert "votes" (lazy (
        Array.foralli
          (fun _ x -> Crypto.verify_vote e.election e.fingerprint x)
          votes
      ));
      (match e.public_data.election_result with
        | Some r ->
          verbose_assert "encrypted tally" (lazy (
            r.encrypted_tally = Crypto.compute_encrypted_tally e.election votes
          ))
        | None -> ()
      );
    | None -> Printf.eprintf "   no votes available\n%!"
  );
  (match e.public_data.election_result with
    | Some r ->
      verbose_assert "partial decryptions" (lazy (
        Crypto.verify_partial_decryptions
          e.election e.public_data.public_keys r
      ));
      verbose_assert "result" (lazy (Crypto.verify_result e.election r));
    | None -> Printf.eprintf "   no results available\n%!"
  );
  verbose_assert "private keys" (lazy (
    Array.foralli
      (fun _ k -> Crypto.verify_private_key k)
      e.private_data.private_keys
  ));;

let notdotfiles_of_directory dirname =
  Lwt_unix.files_of_directory dirname |>
  Lwt_stream.filter (fun x -> String.length x > 0 && x.[0] <> '.') |>
  Lwt_stream.map (Filename.concat dirname) |>
  Lwt_stream.to_list |>
  Lwt_main.run

let load_election_and_verify_it_all dirname =
  notdotfiles_of_directory dirname |>
  List.map load_election_test_data |>
  List.iter verbose_verify_election_test_data;;

let () = load_election_and_verify_it_all "tests/data"

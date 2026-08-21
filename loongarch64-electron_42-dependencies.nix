{ nixpkgs }:

let
  lib = import (nixpkgs + "/lib");

  pkgs = import nixpkgs {
    system = "loongarch64-linux";
    config.inHydra = true;
  };

  evalPkgs = import nixpkgs {
    system = builtins.currentSystem;
    config.inHydra = true;
  };

  electron = pkgs.electron_42;
  electronDrvPath = builtins.unsafeDiscardStringContext electron.drvPath;

  drvPathAsSource =
    drvPath:
    let
      rawDrvPath = builtins.unsafeDiscardStringContext drvPath;
    in
    builtins.appendContext rawDrvPath {
      ${rawDrvPath}.path = true;
    };

  drvPathWithContext =
    drvPath:
    let
      rawDrvPath = builtins.unsafeDiscardStringContext drvPath;
    in
    builtins.appendContext rawDrvPath {
      ${rawDrvPath}.allOutputs = true;
    };

  outputPathWithContext =
    drvPath: outputName: outputPath:
    let
      rawDrvPath = builtins.unsafeDiscardStringContext drvPath;
      rawOutputPath = builtins.unsafeDiscardStringContext outputPath;
    in
    builtins.appendContext rawOutputPath {
      ${rawDrvPath}.outputs = [ outputName ];
    };

  # Hydra evaluates jobsets in restricted mode, so the outer evaluator cannot
  # read newly instantiated .drv paths directly.  Each local IFD helper reads
  # one breadth-first batch of .drv files supplied as ordinary source inputs.
  # The outer evaluator reads the resulting JSON, discovers the next batch,
  # and repeats until it has traversed the complete inputDrvs graph.
  readDrvBatch =
    drvPaths:
    evalPkgs.runCommandLocal "electron-42-drv-batch.json" {
      nativeBuildInputs = [ evalPkgs.python3 ];

      drvPathsJson = builtins.toJSON (map drvPathAsSource drvPaths);

      passAsFile = [
        "drvPathsJson"
        "drvReader"
      ];
      drvReader = ''
      import json
      import os
      import sys


      def drv_name(drv_path):
          store_name = os.path.basename(drv_path).removesuffix(".drv")
          return store_name[33:] if len(store_name) > 33 else store_name


      def take_header_fields(text):
          prefix = "Derive("
          if not text.startswith(prefix):
              raise ValueError("not a derivation ATerm")

          fields = []
          depth = 0
          in_string = False
          escaped = False
          field_start = len(prefix)

          for position in range(field_start, len(text)):
              character = text[position]

              if in_string:
                  if escaped:
                      escaped = False
                  elif character == "\\":
                      escaped = True
                  elif character == '"':
                      in_string = False
                  continue

              if character == '"':
                  in_string = True
              elif character in "[(":
                  depth += 1
              elif character in "])":
                  depth -= 1
              elif character == "," and depth == 0:
                  fields.append(text[field_start:position])
                  field_start = position + 1
                  if len(fields) == 4:
                      return fields

          raise ValueError("unexpected end of derivation ATerm")


      def decode_tuple_list(field):
          return json.loads(field.replace("(", "[").replace(")", "]"))


      def parse_drv(drv_path):
          with open(drv_path, encoding="utf-8") as drv_file:
              fields = take_header_fields(drv_file.read())

          return {
              "name": drv_name(drv_path),
              "system": json.loads(fields[3]),
              "outputs": {
                  output[0]: output[1]
                  for output in decode_tuple_list(fields[0])
              },
              "inputDrvs": decode_tuple_list(fields[1]),
          }


      drv_paths_path, output_path = sys.argv[1:]
      with open(drv_paths_path, encoding="utf-8") as drv_paths_file:
          drv_paths = json.load(drv_paths_file)

      with open(output_path, "w", encoding="utf-8") as output_file:
          json.dump(
              [parse_drv(drv_path) | {"drvPath": drv_path} for drv_path in drv_paths],
              output_file,
              separators=(",", ":"),
              sort_keys=True,
          )
      '';
    } ''
      python3 "$drvReaderPath" "$drvPathsJsonPath" "$out"
    '';

  crawlDrvGraph =
    seen: frontier:
    if frontier == [ ] then
      [ ]
    else
      let
        batch = builtins.fromJSON (
          builtins.unsafeDiscardStringContext (builtins.readFile (readDrvBatch frontier))
        );
        seenNow = seen // builtins.listToAttrs (
          map (node: {
            name = node.drvPath;
            value = null;
          }) batch
        );
        candidates = builtins.listToAttrs (
          lib.concatMap (
            node:
            map (inputDrv: {
              name = builtins.elemAt inputDrv 0;
              value = null;
            }) node.inputDrvs
          ) batch
        );
        next = lib.filter (drvPath: !(builtins.hasAttr drvPath seenNow)) (
          builtins.attrNames candidates
        );
      in
      batch ++ crawlDrvGraph seenNow next;

  drvNodes = crawlDrvGraph { } [ electronDrvPath ];

  requestedOutputs = lib.foldl' (
    requested: node:
    lib.foldl' (
      result: inputDrv:
      let
        drvPath = builtins.elemAt inputDrv 0;
        outputs = builtins.elemAt inputDrv 1;
      in
      result
      // {
        ${drvPath} = lib.unique ((result.${drvPath} or [ ]) ++ outputs);
      }
    ) requested node.inputDrvs
  )
    {
      ${electronDrvPath} = [ (electron.outputName or "out") ];
    }
    drvNodes;

  buildClosure = lib.concatMap (
    node:
    map (
      outputName:
      let
        output = node.outputs.${outputName} or null;
      in
      if output == null || output == "" then
        throw "missing concrete ${outputName} output for ${node.drvPath}"
      else
        {
          inherit (node) drvPath name system;
          inherit outputName;
          outPath = output;
        }
    ) requestedOutputs.${node.drvPath}
  ) drvNodes;

  sanitizeJobName =
    text:
    lib.concatStrings (
      map (
        character:
        if builtins.match "[A-Za-z0-9_-]" character != null then character else "_"
      ) (lib.stringToCharacters text)
    );

  jobName =
    node:
    let
      hash = builtins.substring 11 32 node.drvPath;
      name = sanitizeJobName node.name;
      shortName = builtins.substring 0 (lib.min 80 (builtins.stringLength name)) name;
    in
    "dep_${hash}_${shortName}_${sanitizeJobName node.outputName}";

  # hydra-eval-jobs only needs this compact derivation interface.  Recreating
  # it here lets each selected output from the recursive inputDrvs graph become
  # an independently named Hydra job without rebuilding wrapper derivations.
  makeHydraJob =
    node:
    let
      commonAttrs = {
        name = node.name;
        system = node.system;
        meta = { };
        outputs = [ node.outputName ];
      };
      outputAttrs = commonAttrs // {
        type = "derivation";
        outputName = node.outputName;
        drvPath = drvPathWithContext node.drvPath;
        outPath = outputPathWithContext node.drvPath node.outputName node.outPath;
      };
    in
    outputAttrs
    // {
      ${node.outputName} = outputAttrs;
    };

  dependencyJobs = builtins.listToAttrs (
    map (node: {
      name = jobName node;
      value = makeHydraJob node;
    }) buildClosure
  );

  allBuildDependencies = pkgs.releaseTools.aggregate {
    name = "electron-42-all-build-dependencies";
    constituents = builtins.attrValues dependencyJobs;
  };
in
dependencyJobs
// {
  electron_42_all_build_dependencies = allBuildDependencies;
}

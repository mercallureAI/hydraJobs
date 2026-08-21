{ nixpkgs }:

let
  lib = import (nixpkgs + "/lib");

  pkgs = import nixpkgs {
    system = "loongarch64-linux";
    config.inHydra = true;
  };

  electron = pkgs.electron_42;

  # A .drv is an ATerm of the form
  # Derive(outputs, inputDrvs, inputSrcs, system, ...).  Split immediately
  # after inputSrcs, then turn the tuple-only header into JSON.  This avoids
  # both import-from-derivation and a deep character-by-character recursion.
  parseDrvHeader =
    text:
    let
      parts = builtins.split "],\"([^\"]+)\"," text;
      prefix = builtins.elemAt parts 0;
      prefixLength = builtins.stringLength prefix;
      header = builtins.fromJSON (
        builtins.unsafeDiscardStringContext (
          builtins.replaceStrings [ "(" ")" ] [ "[" "]" ] (
            "[" + builtins.substring 7 (prefixLength - 7) prefix + "]]"
          )
        )
      );
    in
    if builtins.length parts < 3 || builtins.substring 0 7 text != "Derive(" then
      throw "not a supported derivation ATerm"
    else
      {
        outputs = builtins.elemAt header 0;
        inputDrvs = builtins.elemAt header 1;
        system = builtins.unsafeDiscardStringContext (
          builtins.elemAt (builtins.elemAt parts 1) 0
        );
      };

  drvPathWithContext =
    drvPath:
    builtins.appendContext drvPath {
      ${drvPath}.allOutputs = true;
    };

  outputPathWithContext =
    drvPath: outputName: outputPath:
    builtins.appendContext outputPath {
      ${drvPath}.outputs = [ outputName ];
    };

  drvNameFromPath =
    drvPath:
    let
      storeName = lib.removeSuffix ".drv" (builtins.baseNameOf drvPath);
      storeNameLength = builtins.stringLength storeName;
    in
    if storeNameLength > 33 then
      builtins.substring 33 (storeNameLength - 33) storeName
    else
      storeName;

  parseDrv =
    drvPath:
    let
      header = parseDrvHeader (builtins.readFile (drvPathWithContext drvPath));
    in
    {
      name = drvNameFromPath drvPath;
      system = header.system;

      outputs = builtins.listToAttrs (
        map (output: {
          name = builtins.elemAt output 0;
          value = builtins.elemAt output 1;
        }) header.outputs
      );

      inputDrvs = map (input: {
        drvPath = builtins.elemAt input 0;
        outputs = builtins.elemAt input 1;
      }) header.inputDrvs;
    };

  makeNode =
    drvPath: outputName:
    let
      plainDrvPath = builtins.unsafeDiscardStringContext drvPath;
    in
    {
      key = "${plainDrvPath}!${outputName}";
      drvPath = plainDrvPath;
      inherit outputName;
      info = parseDrv plainDrvPath;
    };

  buildClosure = builtins.genericClosure {
    startSet = [ (makeNode electron.drvPath (electron.outputName or "out")) ];

    operator =
      node:
      lib.concatMap (
        input: map (makeNode input.drvPath) input.outputs
      ) node.info.inputDrvs;
  };

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
      name = sanitizeJobName node.info.name;
      shortName = builtins.substring 0 (lib.min 80 (builtins.stringLength name)) name;
    in
    "dep_${hash}_${shortName}_${sanitizeJobName node.outputName}";

  # hydra-eval-jobs only needs this compact derivation interface.  Recreating
  # it here lets each selected output from the recursive inputDrvs graph become
  # an independently named Hydra job without rebuilding wrapper derivations.
  makeHydraJob =
    node:
    let
      outputPath =
        node.info.outputs.${node.outputName}
          or (throw "output ${node.outputName} is missing from ${node.drvPath}");
      commonAttrs = {
        name = node.info.name;
        system = node.info.system;
        meta = { };
        outputs = [ node.outputName ];
      };
      outputAttrs = commonAttrs // {
        type = "derivation";
        outputName = node.outputName;
        drvPath = drvPathWithContext node.drvPath;
        outPath = outputPathWithContext node.drvPath node.outputName outputPath;
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

#!/usr/bin/env ruby
# frozen_string_literal: true

# Aggiunge a ios/Runner.xcodeproj (gia' presente nel repository):
#   1) il target Widget Extension "RadioWidgetsExtension" con i file di ios_widget/
#   2) l'embed dell'estensione nel target Runner
#   3) l'App Group in ios/Runner/Runner.entitlements (si AGGIUNGE a CarPlay, non lo sostituisce)
#
# Uso (dalla radice del repository):  ruby scripts/add_radio_widget_target.rb
# Richiede la gemma "xcodeproj" (installata con CocoaPods).
# Adattato da scripts/add_widget_target.rb di Road Dashboard (collaudato su Codemagic).
# Se qualcosa non va esce con codice 1 e un messaggio "ERRORE: ..." leggibile.

require 'fileutils'

def step(msg)
  puts "==> #{msg}"
end

def fail!(msg)
  warn "ERRORE: #{msg}"
  exit 1
end

begin
  require 'xcodeproj'
rescue LoadError
  fail!('la gemma Ruby "xcodeproj" non e disponibile. Installala con: gem install xcodeproj --no-document')
end

APP_TARGET       = 'Runner'
WIDGET_TARGET    = 'RadioWidgetsExtension'
APP_BUNDLE_ID    = 'it.photopix.saurosoft-radio'
WIDGET_BUNDLE_ID = 'it.photopix.saurosoft-radio.widget'
APP_GROUP        = 'group.it.photopix.saurosoft-radio'
# containerBackground richiede iOS 17. L'app resta a 13: sui telefoni piu' vecchi manca solo il widget.
WIDGET_IOS       = '17.0'

ROOT        = File.expand_path('..', __dir__)
IOS_DIR     = File.join(ROOT, 'ios')
PROJECT     = File.join(IOS_DIR, 'Runner.xcodeproj')
SRC_DIR     = File.join(ROOT, 'ios_widget')
DEST_DIR    = File.join(IOS_DIR, WIDGET_TARGET)
SWIFT_FILES = %w[RadioWidgets.swift].freeze
OTHER_FILES = %w[Info.plist RadioWidget.entitlements].freeze
GROUP_KEY   = 'com.apple.security.application-groups'

step "Controllo i file di partenza"
fail!("manca #{PROJECT}") unless File.directory?(PROJECT)
(SWIFT_FILES + OTHER_FILES).each do |f|
  fail!("manca il file #{File.join(SRC_DIR, f)}") unless File.file?(File.join(SRC_DIR, f))
end

begin
  step "Apro #{PROJECT}"
  project = Xcodeproj::Project.open(PROJECT)

  app = project.targets.find { |t| t.name == APP_TARGET }
  fail!("target '#{APP_TARGET}' non trovato in Runner.xcodeproj (target presenti: #{project.targets.map(&:name).join(', ')})") if app.nil?

  if project.targets.any? { |t| t.name == WIDGET_TARGET }
    puts "Il target #{WIDGET_TARGET} esiste gia: non faccio nulla."
    exit 0
  end

  # ---------------------------------------------------------------- file
  step "Copio i file dell'estensione in ios/#{WIDGET_TARGET}/"
  FileUtils.mkdir_p(DEST_DIR)
  (SWIFT_FILES + OTHER_FILES).each { |f| FileUtils.cp(File.join(SRC_DIR, f), File.join(DEST_DIR, f)) }

  # xcconfig dell'estensione: include solo Generated.xcconfig di Flutter, cosi' l'estensione
  # eredita FLUTTER_BUILD_NAME / FLUTTER_BUILD_NUMBER (stessa versione dell'app, obbligatoria
  # per App Store) senza includere i pod di Runner.
  flutter_dir = File.join(IOS_DIR, 'Flutter')
  fail!("manca la cartella #{flutter_dir}") unless File.directory?(flutter_dir)
  File.write(File.join(flutter_dir, 'Widget.xcconfig'), "#include \"Generated.xcconfig\"\n")

  # -------------------------------------------------------------- target
  step "Creo il target #{WIDGET_TARGET} (Widget Extension, iOS #{WIDGET_IOS})"
  widget = project.new_target(:app_extension, WIDGET_TARGET, :ios, WIDGET_IOS)

  group = project.main_group.new_group(WIDGET_TARGET, WIDGET_TARGET)
  swift_refs = SWIFT_FILES.map { |f| group.new_file(f) }
  OTHER_FILES.each { |f| group.new_file(f) }
  widget.add_file_references(swift_refs)

  # Riferimento sempre dalla radice del progetto (ios/): percorso ios/Flutter/Widget.xcconfig.
  xcconfig_ref = project.main_group.new_file('Flutter/Widget.xcconfig')

  begin
    widget.add_system_framework(%w[WidgetKit SwiftUI])
  rescue StandardError => e
    puts "Avviso: add_system_framework non riuscito (#{e.message}); il collegamento avviene comunque con l'autolink degli import."
  end

  widget.build_configurations.each do |config|
    config.base_configuration_reference = xcconfig_ref
    config.build_settings.merge!(
      'PRODUCT_BUNDLE_IDENTIFIER'   => WIDGET_BUNDLE_ID,
      'PRODUCT_NAME'                => '$(TARGET_NAME)',
      'INFOPLIST_FILE'              => "#{WIDGET_TARGET}/Info.plist",
      'GENERATE_INFOPLIST_FILE'     => 'NO',
      'CODE_SIGN_ENTITLEMENTS'      => "#{WIDGET_TARGET}/RadioWidget.entitlements",
      'IPHONEOS_DEPLOYMENT_TARGET'  => WIDGET_IOS,
      'TARGETED_DEVICE_FAMILY'      => '1',
      'SWIFT_VERSION'               => '5.0',
      'SKIP_INSTALL'                => 'YES',
      'CODE_SIGN_STYLE'             => 'Manual',
      'LD_RUNPATH_SEARCH_PATHS'     => ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks'],
      'SDKROOT'                     => 'iphoneos'
    )
  end

  # ------------------------------------------------- embed in Runner
  step "Aggiungo la fase 'Embed Foundation Extensions' al target #{APP_TARGET}"
  embed = app.build_phases.find do |p|
    p.is_a?(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase) && p.name == 'Embed Foundation Extensions'
  end
  embed ||= app.new_copy_files_build_phase('Embed Foundation Extensions')
  embed.symbol_dst_subfolder_spec = :plug_ins
  build_file = embed.add_file_reference(widget.product_reference, true)
  build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
  app.add_dependency(widget)

  # La fase di embed deve stare PRIMA di "Thin Binary" (altrimenti Xcode segnala
  # "Cycle inside Runner; building could produce unreliable results").
  phases = app.build_phases
  thin_idx = phases.index { |p| p.respond_to?(:name) && p.name.to_s.include?('Thin Binary') }
  embed_idx = phases.index(embed)
  if thin_idx && embed_idx && embed_idx > thin_idx
    if phases.respond_to?(:move)
      phases.move(embed, thin_idx)
    elsif phases.respond_to?(:move_from)
      phases.move_from(embed_idx, thin_idx)
    else
      fail!("non riesco a riordinare le fasi di build di Runner (metodo move non disponibile in questa versione di xcodeproj)")
    end
  end

  step "Salvo il progetto"
  project.save
rescue SystemExit
  raise
rescue StandardError => e
  warn "ERRORE inatteso: #{e.class}: #{e.message}"
  warn e.backtrace.first(8).join("\n")
  exit 1
end

# ------------------------------------------- entitlements di Runner (CarPlay + App Group)
# Il file esiste gia' (carplay-audio): si aggiunge solo l'App Group, con PlistBuddy.
step "Aggiungo l'App Group #{APP_GROUP} a ios/Runner/Runner.entitlements (CarPlay resta)"
ent = File.join(IOS_DIR, 'Runner', 'Runner.entitlements')
fail!("manca #{ent}") unless File.file?(ent)
pb = '/usr/libexec/PlistBuddy'
system(pb, '-c', "Delete :#{GROUP_KEY}", ent, err: File::NULL, out: File::NULL)
fail!('PlistBuddy: Add array non riuscito') unless system(pb, '-c', "Add :#{GROUP_KEY} array", ent)
fail!('PlistBuddy: Add group non riuscito') unless system(pb, '-c', "Add :#{GROUP_KEY}:0 string #{APP_GROUP}", ent)
system(pb, '-c', 'Print', ent)

# ------------------------------------------------------------ verifica
step "Verifico il risultato"
check = Xcodeproj::Project.open(PROJECT)
w = check.targets.find { |t| t.name == WIDGET_TARGET }
a = check.targets.find { |t| t.name == APP_TARGET }
fail!("verifica: il target #{WIDGET_TARGET} non risulta nel progetto salvato") if w.nil?
embedded = a.copy_files_build_phases.any? do |p|
  p.name == 'Embed Foundation Extensions' && p.files.any? { |f| f.file_ref == w.product_reference }
end
fail!("verifica: l'estensione non risulta incorporata in #{APP_TARGET}") unless embedded
fail!("verifica: nessun file Swift nel target #{WIDGET_TARGET}") if w.source_build_phase.files.empty?
fail!("verifica: CODE_SIGN_ENTITLEMENTS mancante su #{APP_TARGET}") unless a.build_configurations.all? { |c| c.build_settings['CODE_SIGN_ENTITLEMENTS'] }

puts "Target: #{check.targets.map(&:name).join(', ')}"
puts "Fasi di #{APP_TARGET}: #{a.build_phases.map { |p| p.respond_to?(:name) && p.name ? p.name : p.isa }.join(' | ')}"
puts "Estensione #{WIDGET_TARGET} (#{WIDGET_BUNDLE_ID}) aggiunta e incorporata in #{APP_TARGET} (#{APP_BUNDLE_ID})."

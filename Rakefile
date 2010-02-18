require 'rake'

begin
  require 'jeweler'
  Jeweler::Tasks.new do |gemspec|
    gemspec.name = "acts_as_service"
    gemspec.summary = "Makes it very easy to create a service-like class that's easy to start and stop"
    gemspec.description = <<-DESC
A gem with a mixin to let you turn a class into something that runs like a service,
which you can MyService.start, MyService.stop, and MyService.restart. It tracks
its own pid. For now, pretty sure it requires that the class is running inside
a rails context (e.g. run by script/runner MyService.start), but that could
probably be changed without too much difficulty.
DESC
    gemspec.email = "percivalatumamibuddotcom"
    gemspec.homepage = "http://github.com/bmpercy/acts_as_service"
    gemspec.authors = ['Brian Percival']
    gemspec.files = ["acts_as_service.gemspec",
                     "[A-Z]*.*",
                     "lib/**/*.rb"]
  end
  Jeweler::GemcutterTasks.new
rescue LoadError
  puts "Jeweler not available. Install it with: sudo gem install technicalpickles-jeweler -s http://gems.github.com"
end

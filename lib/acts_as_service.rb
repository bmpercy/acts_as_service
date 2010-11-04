# module that makes it easy to turn a class into a service, giving it methods
# like stop, start, restart for easy cronjobbage, etc.
#
# simply require 'acts_as_service' in your class' file and then call
# acts_as_service in your class definition, then implement a few required
# and option methods:
#  - required:
#     - self.perform_work_chunk: do a chunk of work that the service is intended
#                                to do. note that this method should return
#                                periodically to enable shutdown. alternatively,
#                                your method /could/ (but not recommended) check
#                                the status to see if it's set to SHUTTING_DOWN
#                                and return if so. otherwise, the shutdown
#                                by this module will not work.
#
# - optional:
#     - self.service_name: return the string name of the service.
#                          default is the class name (without module prefixes)
#     - self.service_pid_filename: path to the file that should contain the PID for
#                                  the process while it's running.
#                                  default is #{RAILS_ROOT}/tmp/pids/<underscore version of service name>
#     - self.sleep_time: seconds to sleep between calls to peform_work_chunk
#                        default: no sleep till brooklyn!
#     - self.sleep_check_timeout: while 'sleeping' between work chunks, how many
#                                 seconds to sleep between checking if the
#                                 service has been shut down. default is 2 seconds,
#                                 but you may want to override to make shorter
#                                 (will give better resolution on sleep_time, but
#                                 uses a little more cpu) or longer (if you don't
#                                 care about how quickly the service shuts down)
#     - self.after_start: a hook to run a method after the service is started
#                         but before first call to perform_work_chunk
#     - self.before_stop: a hook to run a method before final shutdown (and
#                         after last run to perform_work_chunk)
#
# you can also call self.shutdown() from within your perform_work_chunk
# code to initiate a shutdown (don't just exit() because there's pidfile
# cleanup etc. to peform).
#
# # my_service.rb:
# 
# require 'acts_as_service'
# 
# class MyService
# 
#   acts_as_service
# 
#   # ... define methods
#
# end
#-------------------------------------------------------------------------------
module ActsAsService

  ACTS_AS_SERVICE_RUNNING = 'running'
  ACTS_AS_SERVICE_OTHER_RUNNING = 'other running'
  ACTS_AS_SERVICE_STOPPED = 'stopped'
  ACTS_AS_SERVICE_SHUTTING_DOWN = 'shutting down'
  ACTS_AS_SERVICE_PID_NO_PROCESS = 'pid no process'

  # how long to sleep before checking to see if sleep time has elapsed...allows
  # for sleeping for a long time between work chunks, but quicker response to
  # shutdowns. this is measured in seconds
  # this is the DEFAULT value if the service doesn't define the
  # +sleep_check_timeout+ method itself
  SLEEP_CHECK_TIMEOUT = 2

  def self.included(base)
    base.extend ClassMethods
  end

  module ClassMethods
    # starts the process if it's not already running
    #---------------------------------------------------------------------------
    def start
      begin
        if _status != ACTS_AS_SERVICE_STOPPED &&
             _status != ACTS_AS_SERVICE_PID_NO_PROCESS

          puts "#{_display_name} (#{_pid_file_pid}) is already running. Ignoring."
        else
          # clean out a stale pid
          if _status == ACTS_AS_SERVICE_PID_NO_PROCESS
            puts 'Pid file exists but process is not running. Removing old pid file.'
            File.delete(_pid_filename)
          end
          puts "Starting #{_display_name} (#{_pid})...."
          puts "Run #{name}.stop to stop\n\n"
          File.open(_pid_filename, 'w') {|f| f.write(_pid.to_s) }
          if self.respond_to?(:after_start)
            after_start
          end
          _sleep_till = Time.now - 1
          while (_status == ACTS_AS_SERVICE_RUNNING)
            if Time.now >= _sleep_till
              perform_work_chunk

              # only reset sleep till if asked to; otherwise, just perform next
              # work chunk right away (never change _sleep_till)
              if self.respond_to?(:sleep_time)
                _sleep_till = Time.now + self.sleep_time
              end
            else
              _check_time_interval = if self.respond_to? :sleep_check_timeout
                                       self.sleep_check_timeout
                                     else
                                       SLEEP_CHECK_TIMEOUT
                                     end

              sleep [_check_time_interval, _sleep_till - Time.now].min
            end
          end
          puts "Shutting down #{_display_name} (#{_pid})"
          File.delete(_pid_filename)
        end
      # if something happens, dump an error and clean up the pidfile if
      # it's owned by this process
      rescue Object => e
        puts "ERROR: #{e}\n#{e.respond_to?(:backtrace) ? e.backtrace.join("\n  ") : ''}"
        puts "Exiting (#{_pid})\n"
        if _process_running?
          File.delete(_pid_filename)
        end
      end
    end


    # stops the process if it's running
    #---------------------------------------------------------------------------
    def stop
      if _status == ACTS_AS_SERVICE_STOPPED
        puts "#{_display_name} is not running"
      elsif _status == ACTS_AS_SERVICE_PID_NO_PROCESS
        puts 'Pid file exists but process is not running. Removing old pid file.'
        File.delete(_pid_filename)
      else
        pid_to_stop = _pid_file_pid
        puts "Stopping #{_display_name} (#{pid_to_stop})...."
        shutdown
        while (_status != ACTS_AS_SERVICE_STOPPED)
          sleep(1)
        end
        puts "#{_display_name} (#{pid_to_stop}) stopped\n"
      end
    end


    # stops the current service process and runs a new one in the current process
    #-----------------------------------------------------------------------------
    def restart
      stop
      start
    end


    # initiate shutdown. call this from within perform_work_chunk if the service's
    # work is done and it should shut down (makes sense for cronjobs, say)
    #-----------------------------------------------------------------------------
    def shutdown
      if self.respond_to?(:before_stop)
        before_stop
      end
      # change the pid file so the original process sees this 'stop' signal 
      File.open(_pid_filename, 'a') do |f|
        f.write("\n#{ACTS_AS_SERVICE_SHUTTING_DOWN}")
      end
    end


    # method for outside consumption of status info. hopefully not
    # tempting method name for class-writers to conflict with...
    #---------------------------------------------------------------------------
    def service_running?
      _status == ACTS_AS_SERVICE_RUNNING || _status == ACTS_AS_SERVICE_OTHER_RUNNING
    end


    # method for outside consumption of the pid value. hopefully not
    # tempting method name for class-writers to conflict with...
    #---------------------------------------------------------------------------
    def service_pid
      _pid_file_pid
    end


    #---------------------------------------------------------------------------
    # helper methods, no real need to access these from client code
    #---------------------------------------------------------------------------


    # fetches the service's name, using class name as default
    #---------------------------------------------------------------------------
    def _display_name
      @@_display_name ||= (respond_to?(:service_name) ?
                           service_name :
                           name.split("::").last)
    end


    # returns the pid filename
    #---------------------------------------------------------------------------
    def _pid_filename
      if defined?(@@_pid_filename)
        return @@_pid_filename
      end

      if respond_to?(:service_pid_filename)
        @@_pid_filename = service_pid_filename
      else
        @@_pid_filename = File.join(RAILS_ROOT, 'tmp', 'pids',
                                    "#{_display_name.underscore.gsub(/\s+/, '_')}.pid")
      end
      return @@_pid_filename
    end


    # the current status of the service. possible values:
    #  ACTS_AS_SERVICE_STOPPED        : no service process is running
    #  ACTS_AS_SERVICE_SHUTTING_DOWN  : process currently shutting down
    #  ACTS_AS_SERVICE_RUNNING        : the current process is the service process
    #  ACTS_AS_SERVICE_OTHER_RUNNING  : another pid is running the service
    #  ACTS_AS_SERVICE_PID_NO_PROCESS : pidfile exists, but no process running
    #-----------------------------------------------------------------------------
    def _status
      _status = nil

      # logic:
      # if the pid file doesn't exist, it's stopped
      # otherwise, if 'shutting down', it's shutting down
      #            or if the pidfile's pid is running, another process is running
      #            or if the pidfile's pid matches this process, it's running
      #            otherwise, the pidfile's there but no one's running
      if !_pid_file_exists?  
        _status = ACTS_AS_SERVICE_STOPPED
      elsif Regexp.new(ACTS_AS_SERVICE_SHUTTING_DOWN) =~ _pid_file_content
        _status = ACTS_AS_SERVICE_SHUTTING_DOWN
      elsif _process_running?
        _status = ACTS_AS_SERVICE_RUNNING
      elsif _pid_file_process_running?
        _status = ACTS_AS_SERVICE_OTHER_RUNNING
      else
        _status = ACTS_AS_SERVICE_PID_NO_PROCESS
      end

      return _status
    end 


    # indicates if the pid file exists for this service
    #---------------------------------------------------------------------------
    def _pid_file_exists?
      File.exist?(_pid_filename)    
    end
    

    # returns the entire contents of the pid file
    #---------------------------------------------------------------------------
    def _pid_file_content
      begin
        f = File.open(_pid_filename, 'r')
        return f.blank? ? f : f.read
      rescue Errno::ENOENT
        return nil
      end
    end


    # the pid found in the pidfile (if it exists, nil if it doesn't)
    #---------------------------------------------------------------------------
    def _pid_file_pid
      /^(\d*)$/ =~ _pid_file_content
      return $1.blank? ? nil : $1.to_i
    end


    # the current process' pid
    #---------------------------------------------------------------------------
    def _pid
      @@_pid ||= Process.pid
    end


    # Checks to see if the process pointed to by the pid file is actually
    # running Note that I couldn't find a good way to check for the status of a
    # different process by its pid, so this checks to see if the proces has a
    # process group id, and if the process doesn't exist, an exception is
    # returned
    #---------------------------------------------------------------------------
    def _pid_file_process_running?
      begin
        Process.getpgid(_pid_file_pid)
        return true
      rescue
        return false
      end
    end


    # returns true if the current process is the pid in the pid file. false
    # otherwise
    #---------------------------------------------------------------------------
    def _process_running?
      return _pid == _pid_file_pid
    end

  end
end

# gives us the handy acts_as_service method we can declare inside any class
#-------------------------------------------------------------------------------
class Object
  def self.acts_as_service
    self.send(:include, ActsAsService)
  end
end


# totally addicted to blank?
#-------------------------------------------------------------------------------
class File
  def blank?
    return self.nil?
  end
end
class String
  def blank?
    return self.nil? || self == ''
  end
end
class NilClass
  def blank?
    return self.nil?
  end
end

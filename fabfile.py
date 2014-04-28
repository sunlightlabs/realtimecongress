import time
from fabric.api import run, execute, env

environment = "production"

env.use_ssh_config = True
env.hosts = ["rtc@rtc"]

branch = "master"
repo = "git://github.com/sunlightlabs/realtimecongress.git"

home = "/projects/rtc"
shared_path = "%s/shared" % home
versions_path = "%s/versions" % home
version_path = "%s/%s" % (versions_path, time.strftime("%Y%m%d%H%M%S"))
current_path = "%s/current" % home

# how many old releases to be kept at deploy-time
keep = 10


## can be run only as part of deploy

def checkout():
  run('git clone -q -b %s %s %s' % (branch, repo, version_path))

def links():
  run("ln -s %s/config.yml %s/config/config.yml" % (shared_path, version_path))
  run("ln -s %s/mongoid.yml %s/config/mongoid.yml" % (shared_path, version_path))
  run("ln -s %s/config.ru %s/config.ru" % (shared_path, version_path))
  run("ln -s %s/unicorn.rb %s/unicorn.rb" % (shared_path, version_path))
  run("ln -s %s/data %s/data" % (shared_path, version_path))

def dependencies():
  run("cd %s && bundle install --local" % version_path)

def create_indexes():
  run("cd %s && rake create_indexes" % version_path)

def make_current():
  run('rm -f %s && ln -s %s %s' % (current_path, version_path, current_path))

def cleanup():
  versions = run("ls -x %s" % versions_path).split()
  # destroy all but the most recent X
  destroy = versions[:-keep]

  for version in destroy:
    command = "rm -rf %s/%s" % (versions_path, version)
    run(command)


## can be run on their own

def set_crontab():
  run("cd %s && rake set_crontab environment=%s current_path=%s" % (current_path, environment, current_path))

def disable_crontab():
  run("cd %s && rake disable_crontab" % current_path)

def start():
  run("cd %s && unicorn -D -l %s/rtc.sock -c unicorn.rb" % (current_path, shared_path))

def stop():
  run("kill `cat %s/unicorn.pid`" % shared_path)

def restart():
  execute(stop)
  execute(start)

def deploy():
  execute(checkout)
  execute(links)
  execute(dependencies)
  execute(create_indexes)
  execute(make_current)
  execute(set_crontab)
  execute(restart)
  execute(cleanup)

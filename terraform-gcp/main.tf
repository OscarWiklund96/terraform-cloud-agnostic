// Configure the Google Cloud provider
provider "google" {
  credentials = file(var.credentials)
  project     = var.project_id
  region      = var.region
}

# Picture bucket
resource "google_storage_bucket" "terraform-resource-bucket" {
  name     = "uploaded-pictures-${var.project_id}"
  location = "EU"

  uniform_bucket_level_access = true
  force_destroy               = true
}

#Give allusers access to view content of the bucket
resource "google_storage_bucket_iam_member" "member" {
  bucket = google_storage_bucket.terraform-resource-bucket.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

#Bucket with thumbnails
resource "google_storage_bucket" "thumbnail-bucket" {
  name     = "thumbnails-${var.project_id}"
  location = "EU"

  uniform_bucket_level_access = true
  force_destroy               = true

}

#Give allusers access to view content of the bucket
resource "google_storage_bucket_iam_member" "member-thumbnails" {
  bucket = google_storage_bucket.thumbnail-bucket.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

#Bucket for code zipz
resource "google_storage_bucket" "code-bucket" {
  name          = "code-bucket-${var.project_id}"
  location      = "EU"
  force_destroy = true
}
#Zip object with code.
resource "google_storage_bucket_object" "code-archive" {
  name   = "function.zip"
  bucket = google_storage_bucket.code-bucket.name
  source = "./code/function.zip"
}

resource "google_cloudfunctions_function" "pic-upload-function" {
  name        = "pic-upload-function"
  description = "Analyses the uploaded picture."
  runtime     = "nodejs14"

  available_memory_mb   = 256
  source_archive_bucket = google_storage_bucket.code-bucket.name
  source_archive_object = google_storage_bucket_object.code-archive.name
  event_trigger {
    event_type = "google.storage.object.finalize"
    resource   = google_storage_bucket.terraform-resource-bucket.name
  }
  entry_point = "vision_analysis"
}

#Create app engine application in order to provision a Firestore db
resource "google_app_engine_application" "app" {
  project       = var.project_id
  location_id   = "europe-west"
  database_type = "CLOUD_FIRESTORE"
}

resource "google_firestore_document" "mydoc" {
  project     = var.project_id
  collection  = "pictures"
  document_id = "inital-document"
  fields      = ""
}

resource "google_firestore_index" "my-index" {
  project = var.project_id

  collection = "pictures"

  fields {
    field_path = "thumbnail"
    order      = "DESCENDING"
  }

  fields {
    field_path = "created"
    order      = "DESCENDING"
  }

}

#Cloud run for thumbnail service
resource "google_cloud_run_service" "thumbnail-cloud-run" {
  name     = "thumbnail-service"
  location = "europe-west3"

  template {
    spec {
      containers {
        image = "gcr.io/terraform-pic-a-daily-2/thumbnail-service"
        env {
          name  = "BUCKET_THUMBNAILS"
          value = "thumbnails-${var.project_id}"
        }
      }
    }
  }
  traffic {
    percent         = 100
    latest_revision = true
  }
}

#Pubsub Topic
resource "google_pubsub_topic" "thumbnail-topic" {
  name = "cloudstorage-cloudrun-topic"
}


data "google_storage_project_service_account" "gcs_account" {
}
resource "google_pubsub_topic_iam_binding" "topic-iam" {
  project = var.project_id
  topic = google_pubsub_topic.thumbnail-topic.name
  role = "roles/pubsub.publisher"
  members = ["serviceAccount:${data.google_storage_project_service_account.gcs_account.email_address}"]
}





#Notification from bucket upload
resource "google_storage_notification" "upload-notification" {
  bucket         = google_storage_bucket.terraform-resource-bucket.name
  payload_format = "JSON_API_V1"
  topic          = google_pubsub_topic.thumbnail-topic.name
  event_types    = ["OBJECT_FINALIZE"]
  custom_attributes = {
        new-attribute = "new-attribute-value"
    }
  depends_on = [google_pubsub_topic_iam_binding.topic-iam]
}

#Service account for subscrition
resource "google_service_account" "service-account-pubsub" {
  account_id   = "${google_pubsub_topic.thumbnail-topic.name}-sa"
  display_name = "Cloud Run Pub/Sub Invoker"
}

data "google_iam_policy" "pubsub-service-policy" {
  binding {
    role = "roles/run.invoker"

    members = [
      "serviceAccount:${google_service_account.service-account-pubsub.account_id}@${var.project_id}.iam.gserviceaccount.com",
    ]
  }
}

resource "google_cloud_run_service_iam_policy" "policy" {
  location = google_cloud_run_service.thumbnail-cloud-run.location
  project = google_cloud_run_service.thumbnail-cloud-run.project
  service = google_cloud_run_service.thumbnail-cloud-run.name
  policy_data = data.google_iam_policy.pubsub-service-policy.policy_data
}

#Create pubsub subscribition
resource "google_pubsub_subscription" "cloudrun-subscription" {
  name  = "${google_pubsub_topic.thumbnail-topic.name}-subscription"
  topic = google_pubsub_topic.thumbnail-topic.name

  push_config {
    push_endpoint = google_cloud_run_service.thumbnail-cloud-run.status[0].url
    oidc_token {
      service_account_email = "${google_service_account.service-account-pubsub.account_id}@${var.project_id}.iam.gserviceaccount.com"
    }
  }
}

#Add member to the subscription
resource "google_pubsub_subscription_iam_member" "subscriber" {
  subscription = google_pubsub_subscription.cloudrun-subscription.name
  role         = "roles/editor"
  member       = "serviceAccount:${google_service_account.service-account-pubsub.account_id}@${var.project_id}.iam.gserviceaccount.com"
}


#Cloud run for thumbnail service
resource "google_cloud_run_service" "collage-cloud-run" {
  name     = "collage-service"
  location = "europe-west3"

  template {
    spec {
      containers {
        image = "gcr.io/terraform-pic-a-daily-2/collage-service"
        env {
          name  = "BUCKET_THUMBNAILS"
          value = "thumbnails-${var.project_id}"
        }
      }
    }
  }
  traffic {
    percent         = 100
    latest_revision = true
  }
}

resource "google_service_account" "collage-sa" {
  account_id   = "collage-scheduler-sa"
  display_name = "Collage Scheduler Service Account"
}

data "google_iam_policy" "collage-service" {
  binding {
    role = "roles/run.invoker"

    members = [
      "serviceAccount:${google_service_account.collage-sa.account_id}@${var.project_id}.iam.gserviceaccount.com",
    ]
  }
}

resource "google_cloud_run_service_iam_policy" "collage-policy" {
  location = google_cloud_run_service.collage-cloud-run.location
  project = google_cloud_run_service.collage-cloud-run.project
  service = google_cloud_run_service.collage-cloud-run.name
  policy_data = data.google_iam_policy.collage-service.policy_data
}

resource "google_cloud_scheduler_job" "collage-job" {
  name             = "collage-service-job"
  description      = "collage http job"
  schedule         = "0 */2 * * 1-5"

  retry_config {
    retry_count = 1
  }

  http_target {
    http_method = "GET"
    uri         = google_cloud_run_service.collage-cloud-run.status[0].url
    
    oidc_token {
      service_account_email = "${google_service_account.collage-sa.account_id}@${var.project_id}.iam.gserviceaccount.com"
    }
  }
}